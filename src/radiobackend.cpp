#include "radiobackend.h"
#include <QDebug>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusReply>
#include <QDBusUnixFileDescriptor>
#include <QMediaMetaData>
#include <QRandomGenerator>

#include "mprisrootadaptor.h"
#include "mprisplayeradaptor.h"

RadioBackend::RadioBackend(QObject *parent)
    : QObject(parent),
      m_player(new QMediaPlayer(this)),
      m_audioOutput(new QAudioOutput(this)),
      m_icyReader(new IcyStreamReader(this))
{
    m_player->setAudioOutput(m_audioOutput);

    m_reconnectTimer.setSingleShot(true);
    connect(&m_reconnectTimer, &QTimer::timeout, this, &RadioBackend::attemptReconnect);

    m_stallTimer.setSingleShot(true);
    connect(&m_stallTimer, &QTimer::timeout, this, [this]() {
        qDebug() << "Playback stalled past timeout; forcing reconnect";
        // Route recovery through scheduleReconnect so it inherits the backoff
        // and attempt cap and can't spin forever.
        scheduleReconnect();
    });

    // Setup DBus Adaptors
    new MprisRootAdaptor(this);
    new MprisPlayerAdaptor(this);

    QDBusConnection dbus = QDBusConnection::sessionBus();
    dbus.registerObject(QStringLiteral("/org/mpris/MediaPlayer2"), this);
    dbus.registerService(QStringLiteral("org.mpris.MediaPlayer2.patronradio"));

    connect(m_player, &QMediaPlayer::playbackStateChanged, this, [this](QMediaPlayer::PlaybackState state) {
        qDebug() << "QMediaPlayer state changed to:" << state;
        
        bool isNowPlaying = (state == QMediaPlayer::PlayingState);
        if (m_playing != isNowPlaying) {
            m_playing = isNowPlaying;
            if (m_playing) {
                m_reconnectTimer.stop();
                m_stallTimer.stop();
                m_reconnectDelay = 0;
                m_reconnectAttempts = 0;
                m_audioOutput->setVolume(m_volume);
                if (!m_lastError.isEmpty()) {
                    m_lastError.clear();
                    Q_EMIT lastErrorChanged();
                }
            }
            if (m_playing && m_inhibitSleep)
                takeSleepInhibitLock();
            else if (!m_playing) {
                releaseSleepInhibitLock();
                m_audioOutput->setVolume(m_volume);
            }
            Q_EMIT playingChanged();
            Q_EMIT bufferingChanged(); // Re-evaluate buffering icon
            
            QVariantMap changedProps;
            changedProps[QStringLiteral("PlaybackStatus")] = PlaybackStatus();
            changedProps[QStringLiteral("Volume")] = m_volume;
            emitMprisPropertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), changedProps);
        }
    });

    connect(m_player, &QMediaPlayer::mediaStatusChanged, this, [this](QMediaPlayer::MediaStatus status) {
        qDebug() << "QMediaPlayer mediaStatus changed to:" << status;
        // Only clear the buffering flag when we are fully loaded or have enough buffered
        if (status == QMediaPlayer::BufferedMedia) {
            m_buffering = false;
            m_stallTimer.stop(); // recovered on its own
        } else if (status == QMediaPlayer::EndOfMedia) {
            // A live stream should never "end"; if the backend declares EOF we
            // reconnect immediately rather than waiting out the stall timeout.
            if (m_wantsToPlay && !m_currentUrl.isEmpty() && !m_reconnectTimer.isActive()) {
                qDebug() << "Unexpected EndOfMedia on live stream; reconnecting";
                scheduleReconnect();
            }
        } else if (status == QMediaPlayer::StalledMedia || status == QMediaPlayer::BufferingMedia) {
            // Underrun / re-buffering. Give the backend a chance to recover by
            // itself; if it's still not BufferedMedia when the watchdog fires,
            // we force a reconnect. (Re)start the single-shot on each event.
            if (m_wantsToPlay && !m_currentUrl.isEmpty() && !m_reconnectTimer.isActive())
                m_stallTimer.start(STALL_TIMEOUT_MS);
        }
        Q_EMIT bufferingChanged();
    });

    connect(m_player, &QMediaPlayer::errorOccurred, this, [this](QMediaPlayer::Error error, const QString &errorString) {
        qDebug() << "QMediaPlayer ERROR:" << error << errorString;
        m_lastError = errorString;
        Q_EMIT lastErrorChanged();
        if (m_buffering) {
            m_buffering = false;
            Q_EMIT bufferingChanged();
        }
        scheduleReconnect();
    });

    connect(new QMediaDevices(this), &QMediaDevices::audioOutputsChanged, this, [this]() {
        qDebug() << "Audio outputs changed, notifying QML";
        Q_EMIT availableOutputsChanged();
    });

// Custom ICY parser connection
connect(m_icyReader, &IcyStreamReader::streamTitleChanged, this, [this](const QString &title) {
    if (title != m_streamTitle) {
        m_streamTitle = title;
        Q_EMIT streamTitleChanged();

        QVariantMap changedProps;
        changedProps[QStringLiteral("Metadata")] = Metadata();
        emitMprisPropertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), changedProps);
    }
});

connect(m_icyReader, &IcyStreamReader::errorOccurred, this, [this](const QString &err) {
    m_lastError = err;
    Q_EMIT lastErrorChanged();
    scheduleReconnect();
});

connect(m_icyReader, &IcyStreamReader::readyToPlay, this, [this]() {
    if (m_icyReader->isActive()) {
        qDebug() << "IcyStreamReader is ready, handing device to QMediaPlayer";
        m_player->setSourceDevice(m_icyReader, QUrl(m_currentUrl));
        m_audioOutput->setVolume(m_volume);
        m_player->play();
    }
});
}

bool RadioBackend::isPlaying() const { return m_playing; }

bool RadioBackend::isBuffering() const 
{ 
    // We are buffering if the player says so, OR if our custom reader is active but hasn't reached its play-ready threshold yet.
    bool playerBuffering = (m_player->mediaStatus() == QMediaPlayer::BufferingMedia || 
                           m_player->mediaStatus() == QMediaPlayer::StalledMedia || 
                           m_player->mediaStatus() == QMediaPlayer::LoadingMedia);
    
    bool isPaused = (m_player->playbackState() == QMediaPlayer::PausedState);
    bool isActuallyPlaying = (m_player->playbackState() == QMediaPlayer::PlayingState);
    bool readerBuffering = (m_icyReader->isActive() && !isActuallyPlaying && !isPaused);

    return m_buffering || playerBuffering || readerBuffering; 
}

QString RadioBackend::streamTitle() const { return m_streamTitle; }
QString RadioBackend::currentStationName() const { return m_currentStationName; }
QString RadioBackend::currentUrl() const { return m_currentUrl; }
QString RadioBackend::lastError() const { return m_lastError; }

QVariantList RadioBackend::availableOutputs() const
{
    QVariantList list;
    const QList<QAudioDevice> outputs = QMediaDevices::audioOutputs();
    for (const QAudioDevice &device : outputs) {
        QVariantMap map;
        map[QStringLiteral("name")] = device.description();
        map[QStringLiteral("id")] = QString::fromUtf8(device.id());
        list.append(map);
    }
    return list;
}

void RadioBackend::setCurrentStationName(const QString &name)
{
    if (m_currentStationName != name) {
        m_currentStationName = name;
        Q_EMIT currentStationNameChanged();
        
        QVariantMap changedProps;
        changedProps[QStringLiteral("Metadata")] = Metadata();
        emitMprisPropertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), changedProps);
    }
}

void RadioBackend::setCurrentUrl(const QString &url)
{
    // Stream URLs can originate from an untrusted, community-editable directory
    // (radio-browser.info via the "Fix" tool). Only allow http/https so a
    // malicious entry cannot coerce QNetworkAccessManager into reading local
    // files (file://) or probing other schemes.
    if (!url.isEmpty()) {
        const QUrl parsed(url);
        const QString scheme = parsed.scheme().toLower();
        if (!parsed.isValid() || (scheme != QLatin1String("http") && scheme != QLatin1String("https"))) {
            qDebug() << "Refusing non-HTTP(S) stream URL:" << url;
            m_lastError = QStringLiteral("Refused unsupported stream URL");
            Q_EMIT lastErrorChanged();
            return;
        }
    }

    if (m_currentUrl != url) {
        // Stop playback and clear old buffers before switching streams.
        // Order matters: stop the reader FIRST so it wakes any readData() blocked
        // on the FFmpeg/audio worker thread, otherwise m_player->stop() — which
        // synchronously joins that worker — deadlocks the GUI thread. (This is
        // why stop() and attemptReconnect() also stop the reader before the player.)
        m_stallTimer.stop();
        m_icyReader->stop();
        m_player->stop();
        m_player->setSource(QUrl());
        m_audioOutput->setVolume(m_volume);

        m_currentUrl = url;
        
        // Clear stale metadata
        if (!m_streamTitle.isEmpty()) {
            m_streamTitle.clear();
            Q_EMIT streamTitleChanged();
            
            QVariantMap changedProps;
            changedProps[QStringLiteral("Metadata")] = Metadata();
            emitMprisPropertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), changedProps);
        }

        if (!m_buffering) {
            m_buffering = true;
            Q_EMIT bufferingChanged();
        }

        m_icyReader->start(QUrl(url));
        Q_EMIT currentUrlChanged();
    }
}

void RadioBackend::play() {
    m_wantsToPlay = true;
    if (!m_icyReader->isActive()) {
        if (!m_buffering) {
            m_buffering = true;
            Q_EMIT bufferingChanged();
        }
        m_icyReader->start(QUrl(m_currentUrl));
    } else {
        m_player->play();
    }
}
void RadioBackend::pause() {
    // For live streams, pause is equivalent to stop — there's no buffer to hold.
    stop();
}
void RadioBackend::stop() {
    m_wantsToPlay = false;
    m_reconnectTimer.stop();
    m_stallTimer.stop();
    m_reconnectDelay = 0;
    m_reconnectAttempts = 0;
    m_icyReader->stop();
    m_player->stop();
    m_player->setSource(QUrl()); // clear stale source so next setSourceDevice is a fresh start
    m_audioOutput->setVolume(m_volume);

    if (!m_streamTitle.isEmpty()) {
        m_streamTitle.clear();
        Q_EMIT streamTitleChanged();
        
        QVariantMap changedProps;
        changedProps[QStringLiteral("Metadata")] = Metadata();
        emitMprisPropertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), changedProps);
    }
}

bool RadioBackend::routeAudioToBluetooth(const QString &macAddress)
{
    // macAddress comes in from BluezQt, e.g. "00:11:22:33:44:55"
    // System audio devices usually have this address in their ID or description.
    // e.g. bluez_output.00_11_22_33_44_55.a2dp-sink
    QString normalizedMac = macAddress.toLower().replace(QLatin1Char(':'), QLatin1Char('_'));
    
    const QList<QAudioDevice> outputs = QMediaDevices::audioOutputs();
    for (const QAudioDevice &device : outputs) {
        QString devId = QString::fromUtf8(device.id()).toLower();
        QString devDesc = device.description().toLower();
        
        if (devId.contains(normalizedMac) || devDesc.contains(macAddress.toLower())) {
            qDebug() << "Found matching audio output device:" << device.description();
            m_audioOutput->setDevice(device);
            return true;
        }
    }
    
    qDebug() << "Could not find audio output matching MAC address:" << macAddress;
    qDebug() << "Available devices:";
    for (const QAudioDevice &device : outputs) {
        qDebug() << "  - ID:" << device.id() << "Desc:" << device.description();
    }
    return false;
}

void RadioBackend::setAudioOutput(const QString &deviceId)
{
    const QList<QAudioDevice> outputs = QMediaDevices::audioOutputs();
    for (const QAudioDevice &device : outputs) {
        if (QString::fromUtf8(device.id()) == deviceId) {
            qDebug() << "Explicitly setting audio output to:" << device.description();
            m_audioOutput->setDevice(device);
            return;
        }
    }
    qDebug() << "Failed to find explicit audio output device ID:" << deviceId;
}

void RadioBackend::resetAudioOutput()
{
    qDebug() << "Resetting audio output to system default";
    m_audioOutput->setDevice(QMediaDevices::defaultAudioOutput());
}

QString RadioBackend::PlaybackStatus() const
{
    if (m_player->playbackState() == QMediaPlayer::PlayingState)
        return QStringLiteral("Playing");
    // Report "Paused" (not "Stopped") when we have a station loaded.
    // MPRIS controllers hide players in "Stopped" state, making it
    // impossible to resume via KDE Connect / media keys.
    if (!m_currentUrl.isEmpty())
        return QStringLiteral("Paused");
    return QStringLiteral("Stopped");
}

QVariantMap RadioBackend::Metadata() const
{
    QVariantMap meta;
    meta[QStringLiteral("mpris:trackid")] = QVariant::fromValue(QDBusObjectPath("/org/mpris/MediaPlayer2/TrackList/NoTrack"));
    
    QString displayTitle = m_streamTitle.isEmpty() ? m_currentStationName : m_streamTitle;
    if (!displayTitle.isEmpty()) {
        meta[QStringLiteral("xesam:title")] = displayTitle;
    }

    if (!m_currentStationName.isEmpty()) {
        // artist shows as the second line in most MPRIS controllers
        meta[QStringLiteral("xesam:artist")] = QStringList{m_currentStationName};
        meta[QStringLiteral("xesam:album")] = m_currentStationName;
    }

    if (!m_currentUrl.isEmpty()) {
        meta[QStringLiteral("xesam:url")] = m_currentUrl;
    }

    return meta;
}

bool RadioBackend::inhibitSleep() const { return m_inhibitSleep; }

void RadioBackend::setInhibitSleep(bool inhibit)
{
    if (m_inhibitSleep == inhibit)
        return;
    m_inhibitSleep = inhibit;
    if (m_inhibitSleep && m_playing)
        takeSleepInhibitLock();
    else if (!m_inhibitSleep)
        releaseSleepInhibitLock();
    Q_EMIT inhibitSleepChanged();
}

void RadioBackend::takeSleepInhibitLock()
{
    if (m_sleepInhibitFd.isValid())
        return; // already held

    QDBusMessage msg = QDBusMessage::createMethodCall(
        QStringLiteral("org.freedesktop.login1"),
        QStringLiteral("/org/freedesktop/login1"),
        QStringLiteral("org.freedesktop.login1.Manager"),
        QStringLiteral("Inhibit"));

    msg << QStringLiteral("sleep")              // what
        << QStringLiteral("Patron Radio")       // who
        << QStringLiteral("Playing audio")      // why
        << QStringLiteral("block");             // mode

    QDBusReply<QDBusUnixFileDescriptor> reply = QDBusConnection::systemBus().call(msg);
    if (reply.isValid()) {
        m_sleepInhibitFd = reply.value();
        qDebug() << "Sleep inhibit lock acquired";
    } else {
        qDebug() << "Failed to acquire sleep inhibit lock:" << reply.error().message();
    }
}

void RadioBackend::releaseSleepInhibitLock()
{
    if (!m_sleepInhibitFd.isValid())
        return;
    m_sleepInhibitFd = QDBusUnixFileDescriptor(); // closes the fd
    qDebug() << "Sleep inhibit lock released";
}

void RadioBackend::scheduleReconnect()
{
    if (!m_wantsToPlay || m_currentUrl.isEmpty() || m_reconnectTimer.isActive())
        return;

    if (m_reconnectAttempts >= RECONNECT_MAX_ATTEMPTS) {
        qDebug() << "Reconnect limit reached (" << RECONNECT_MAX_ATTEMPTS << " attempts), giving up";
        m_wantsToPlay = false;
        return;
    }

    m_reconnectAttempts++;

    if (m_reconnectDelay == 0)
        m_reconnectDelay = RECONNECT_INITIAL_MS;
    else
        m_reconnectDelay = qMin(m_reconnectDelay * 2, RECONNECT_MAX_MS);

    // Add +/- 25% jitter to avoid thundering herd on stream servers
    int jitter = QRandomGenerator::global()->bounded(m_reconnectDelay / 2) - (m_reconnectDelay / 4);
    int delay = m_reconnectDelay + jitter;

    qDebug() << "Scheduling reconnect in" << delay << "ms (base" << m_reconnectDelay << "+ jitter" << jitter << ")";
    m_reconnectTimer.start(delay);
}

void RadioBackend::attemptReconnect()
{
    if (!m_wantsToPlay || m_currentUrl.isEmpty())
        return;

    qDebug() << "Attempting reconnect to" << m_currentUrl;
    m_stallTimer.stop();
    m_icyReader->stop();
    m_player->stop();
    m_player->setSource(QUrl());
    m_audioOutput->setVolume(m_volume);

    if (!m_buffering) {
        m_buffering = true;
        Q_EMIT bufferingChanged();
    }
    m_icyReader->start(QUrl(m_currentUrl));
}

void RadioBackend::emitMprisPropertiesChanged(const QString &interface, const QVariantMap &changedProperties)
{
    QDBusMessage msg = QDBusMessage::createSignal(
        QStringLiteral("/org/mpris/MediaPlayer2"),
        QStringLiteral("org.freedesktop.DBus.Properties"),
        QStringLiteral("PropertiesChanged"));

    msg << interface << changedProperties << QStringList();
    QDBusConnection::sessionBus().send(msg);
}
