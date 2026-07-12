#include "radiobackend.h"
#include <QDebug>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusReply>
#include <QDBusUnixFileDescriptor>
#include <QMediaMetaData>
#include <QRandomGenerator>
#include <QAudioBufferOutput>
#include <QAudioBuffer>
#include <cmath>
#include <ebur128.h>
#include <KLocalizedString>
#include <KUriFilter>

// Explicit catalog for the few user-facing strings the backend surfaces.
// A plugin must not claim the process-wide application domain (plasmashell
// owns it), so translate against our own domain by name.
static const char *const PR_DOMAIN = "plasma_applet_com.signal11.patronradio";

#include "mprisrootadaptor.h"
#include "mprisplayeradaptor.h"

RadioBackend::RadioBackend(QObject *parent)
    : QObject(parent),
      m_player(new QMediaPlayer(this)),
      m_audioOutput(new QAudioOutput(this)),
      m_icyReader(new IcyStreamReader(this))
{
    m_player->setAudioOutput(m_audioOutput);

    // Tap decoded PCM for loudness measurement (analysis only; audio still plays
    // through m_audioOutput). Buffers arrive on this (the GUI) thread.
    m_audioBufferOutput = new QAudioBufferOutput(this);
    m_player->setAudioBufferOutput(m_audioBufferOutput);
    connect(m_audioBufferOutput, &QAudioBufferOutput::audioBufferReceived,
            this, &RadioBackend::onAudioBuffer);
    m_loudnessTimer.setInterval(LOUDNESS_TICK_MS);
    connect(&m_loudnessTimer, &QTimer::timeout, this, &RadioBackend::updateNormalizationGain);
    m_loudnessTimer.start();

    m_reconnectTimer.setSingleShot(true);
    connect(&m_reconnectTimer, &QTimer::timeout, this, &RadioBackend::attemptReconnect);

    m_stallTimer.setSingleShot(true);
    connect(&m_stallTimer, &QTimer::timeout, this, [this]() {
        qDebug() << "patron-radio:" << "Playback stalled past timeout; forcing reconnect";
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
        qDebug() << "patron-radio:" << "QMediaPlayer state changed to:" << state;
        
        bool isNowPlaying = (state == QMediaPlayer::PlayingState);
        if (m_playing != isNowPlaying) {
            m_playing = isNowPlaying;
            if (m_playing) {
                m_reconnectTimer.stop();
                m_stallTimer.stop();
                m_reconnectDelay = 0;
                m_reconnectAttempts = 0;
                applyEffectiveVolume();
                if (!m_lastError.isEmpty()) {
                    m_lastError.clear();
                    Q_EMIT lastErrorChanged();
                }
            }
            if (m_playing && m_inhibitSleep)
                takeSleepInhibitLock();
            else if (!m_playing) {
                releaseSleepInhibitLock();
                applyEffectiveVolume();
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
        qDebug() << "patron-radio:" << "QMediaPlayer mediaStatus changed to:" << status;
        // Only clear the buffering flag when we are fully loaded or have enough buffered
        if (status == QMediaPlayer::BufferedMedia) {
            m_buffering = false;
            m_stallTimer.stop(); // recovered on its own
        } else if (status == QMediaPlayer::EndOfMedia) {
            // A live stream should never "end"; if the backend declares EOF we
            // reconnect immediately rather than waiting out the stall timeout.
            if (m_wantsToPlay && !m_currentUrl.isEmpty() && !m_reconnectTimer.isActive()) {
                qDebug() << "patron-radio:" << "Unexpected EndOfMedia on live stream; reconnecting";
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
        qDebug() << "patron-radio:" << "QMediaPlayer ERROR:" << error << errorString;
        m_lastError = errorString;
        Q_EMIT lastErrorChanged();
        if (m_buffering) {
            m_buffering = false;
            Q_EMIT bufferingChanged();
        }
        scheduleReconnect();
    });

    connect(new QMediaDevices(this), &QMediaDevices::audioOutputsChanged, this, [this]() {
        qDebug() << "patron-radio:" << "Audio outputs changed, notifying QML";
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
        qDebug() << "patron-radio:" << "IcyStreamReader is ready, handing device to QMediaPlayer";
        m_player->setSourceDevice(m_icyReader, QUrl(m_currentUrl));
        applyEffectiveVolume();
        m_player->play();
    }
});
}

RadioBackend::~RadioBackend()
{
    freeMeter();
}

double RadioBackend::attenuationGainDb(double measuredLufs, double targetLufs)
{
    double g = targetLufs - measuredLufs; // negative when the stream is louder than target
    if (g > 0.0)
        g = 0.0;                          // attenuate only: can't boost past the user's volume
    if (g < -LOUDNESS_MAX_ATTEN_DB)
        g = -LOUDNESS_MAX_ATTEN_DB;
    return g;
}

bool RadioBackend::loudnessMeasurable(double lufs)
{
    // libebur128 reports roughly -HUGE_VAL for silence; ignore those so we don't
    // crank the gain during buffering / dead air.
    return std::isfinite(lufs) && lufs > -60.0;
}

void RadioBackend::onAudioBuffer(const QAudioBuffer &buffer)
{
    if (!m_normalizeLoudness || !m_loudnessAuto || !buffer.isValid())
        return; // manual mode: no measurement, stored gain is just applied

    const QAudioFormat fmt = buffer.format();
    const int ch = fmt.channelCount();
    const int rate = fmt.sampleRate();
    if (ch <= 0 || rate <= 0)
        return;

    // (Re)create the meter if the format changed. Note: this does NOT reset the
    // applied gain, so a seeded station keeps its level while the meter warms up.
    // MODE_I = integrated loudness: gated and cumulative, it converges to the
    // station's overall level and then holds steady (a stable offset, not AGC).
    if (!m_ebur128State || ch != m_eburChannels || rate != m_eburRate) {
        freeMeter();
        m_ebur128State = ebur128_init((unsigned)ch, (unsigned long)rate, EBUR128_MODE_I);
        m_eburChannels = ch;
        m_eburRate = rate;
    }
    auto *st = static_cast<ebur128_state *>(m_ebur128State);
    if (!st)
        return;

    const qsizetype frameCount = buffer.frameCount();
    if (frameCount <= 0)
        return; // nothing to measure; also guards the size_t cast below
    const size_t frames = (size_t)frameCount;
    switch (fmt.sampleFormat()) {
    case QAudioFormat::Int16:
        ebur128_add_frames_short(st, buffer.constData<short>(), frames);
        break;
    case QAudioFormat::Int32:
        ebur128_add_frames_int(st, buffer.constData<int>(), frames);
        break;
    case QAudioFormat::Float:
        ebur128_add_frames_float(st, buffer.constData<float>(), frames);
        break;
    case QAudioFormat::UInt8:
    case QAudioFormat::Unknown:
    default:
        break; // unsupported PCM format for measurement; leave gain unchanged
    }
}

void RadioBackend::updateNormalizationGain()
{
    if (!m_normalizeLoudness || !m_loudnessAuto)
        return; // disabled, or manual mode: hold the seeded/stored gain
    auto *st = static_cast<ebur128_state *>(m_ebur128State);
    if (!st)
        return;

    double lufs = 0.0;
    if (ebur128_loudness_global(st, &lufs) != EBUR128_SUCCESS) // integrated loudness
        return;
    if (!loudnessMeasurable(lufs))
        return; // silence / not enough data yet — hold current gain

    // Integrated loudness is already self-smoothing, so use it directly.
    m_measuredLoudness = lufs;

    const double desired = attenuationGainDb(m_measuredLoudness, LOUDNESS_TARGET_LUFS);

    // Slew toward the target so changes are gradual (no pumping).
    const double delta = desired - m_normGainDb;
    if (delta > LOUDNESS_SLEW_DB_PER_TICK)
        m_normGainDb += LOUDNESS_SLEW_DB_PER_TICK;
    else if (delta < -LOUDNESS_SLEW_DB_PER_TICK)
        m_normGainDb -= LOUDNESS_SLEW_DB_PER_TICK;
    else
        m_normGainDb = desired;

    applyEffectiveVolume();

    // Tell QML to persist once the estimate has moved enough to matter.
    if (!std::isfinite(m_lastEmittedLoudness) ||
        std::fabs(m_measuredLoudness - m_lastEmittedLoudness) > 0.5) {
        m_lastEmittedLoudness = m_measuredLoudness;
        Q_EMIT measuredLoudnessChanged();
    }
}

void RadioBackend::applyEffectiveVolume()
{
    double linear = std::pow(10.0, m_normGainDb / 20.0); // <= 1.0 (m_normGainDb <= 0)
    double v = m_volume * linear;
    if (v < 0.0) v = 0.0;
    if (v > 1.0) v = 1.0;
    m_audioOutput->setVolume(v);
}

void RadioBackend::freeMeter()
{
    if (m_ebur128State) {
        auto *st = static_cast<ebur128_state *>(m_ebur128State);
        ebur128_destroy(&st);
        m_ebur128State = nullptr;
    }
    m_eburChannels = 0;
    m_eburRate = 0;
}

void RadioBackend::beginStreamLoudness()
{
    // Called when a new station starts. Seed the gain from its last-known loudness
    // (set by QML via knownLoudness) so it plays at the right level immediately. If
    // it's never been measured, fall back to an assumed-loud default so it still
    // starts pre-attenuated instead of blasting until the meter converges.
    freeMeter();
    if (m_normalizeLoudness) {
        const double seed = std::isfinite(m_seedLoudness) ? m_seedLoudness : LOUDNESS_DEFAULT_LUFS;
        m_normGainDb = attenuationGainDb(seed, LOUDNESS_TARGET_LUFS);
    } else {
        m_normGainDb = 0.0;
    }
    // Only real, known loudness is exposed/persisted — never the assumed default.
    m_measuredLoudness = m_seedLoudness;
    m_lastEmittedLoudness = kNaN;
    applyEffectiveVolume();
}

void RadioBackend::setLoudnessAuto(bool on)
{
    if (m_loudnessAuto == on)
        return;
    m_loudnessAuto = on;
    if (!on)
        freeMeter(); // stop measuring; the current (seeded/stored) gain is held
    Q_EMIT loudnessAutoChanged();
}

void RadioBackend::setSharedStations(const QString &json)
{
    // Pure relay between instances; no audio side effects. Equality guard stops
    // the broadcast from echoing back through every instance that adopts it.
    if (m_sharedStations == json)
        return;
    m_sharedStations = json;
    Q_EMIT sharedStationsChanged();
}

void RadioBackend::setSharedSettings(const QString &json)
{
    if (m_sharedSettings == json)
        return;
    m_sharedSettings = json;
    Q_EMIT sharedSettingsChanged();
}

QString RadioBackend::webSearchUrl(const QString &query) const
{
    const QString q = query.trimmed();
    if (q.isEmpty())
        return QString();
    // NormalTextFilter applies the user's default web shortcut to plain text,
    // i.e. their configured default search engine.
    KUriFilterData data(q);
    if (KUriFilter::self()->filterSearchUri(data, KUriFilter::NormalTextFilter)) {
        const QUrl u = data.uri();
        if (u.scheme() == QLatin1String("http") || u.scheme() == QLatin1String("https"))
            return u.toString();
    }
    return QString();
}

void RadioBackend::setNormalizeLoudness(bool on)
{
    if (m_normalizeLoudness == on)
        return;
    m_normalizeLoudness = on;
    if (!on) {
        freeMeter();
        m_normGainDb = 0.0; // back to the user's volume immediately
        applyEffectiveVolume();
    }
    Q_EMIT normalizeLoudnessChanged();
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
            qDebug() << "patron-radio:" << "Refusing non-HTTP(S) stream URL:" << url;
            m_lastError = i18nd(PR_DOMAIN, "Refused unsupported stream URL");
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
        beginStreamLoudness(); // seed gain from the station's known loudness, then refine

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
    qDebug() << "patron-radio:" << "play()" << m_currentStationName << m_currentUrl;
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
    qDebug() << "patron-radio:" << "stop()" << m_currentStationName;
    m_wantsToPlay = false;
    m_reconnectTimer.stop();
    m_stallTimer.stop();
    m_reconnectDelay = 0;
    m_reconnectAttempts = 0;
    m_icyReader->stop();
    m_player->stop();
    m_player->setSource(QUrl()); // clear stale source so next setSourceDevice is a fresh start
    freeMeter();
    m_normGainDb = 0.0;
    m_measuredLoudness = kNaN;
    m_lastEmittedLoudness = kNaN;
    applyEffectiveVolume();

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
            qDebug() << "patron-radio:" << "Found matching audio output device:" << device.description();
            m_audioOutput->setDevice(device);
            return true;
        }
    }
    
    qDebug() << "patron-radio:" << "Could not find audio output matching MAC address:" << macAddress;
    qDebug() << "patron-radio:" << "Available devices:";
    for (const QAudioDevice &device : outputs) {
        qDebug() << "patron-radio:" << "  - ID:" << device.id() << "Desc:" << device.description();
    }
    return false;
}

void RadioBackend::setAudioOutput(const QString &deviceId)
{
    const QList<QAudioDevice> outputs = QMediaDevices::audioOutputs();
    for (const QAudioDevice &device : outputs) {
        if (QString::fromUtf8(device.id()) == deviceId) {
            qDebug() << "patron-radio:" << "Explicitly setting audio output to:" << device.description();
            m_audioOutput->setDevice(device);
            return;
        }
    }
    qDebug() << "patron-radio:" << "Failed to find explicit audio output device ID:" << deviceId;
}

void RadioBackend::resetAudioOutput()
{
    qDebug() << "patron-radio:" << "Resetting audio output to system default";
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
        << QStringLiteral("Patron Radio")       // who (app identity, not translated)
        << i18nd(PR_DOMAIN, "Playing audio")    // why (shown in sleep-inhibitor UIs)
        << QStringLiteral("block");             // mode

    QDBusReply<QDBusUnixFileDescriptor> reply = QDBusConnection::systemBus().call(msg);
    if (reply.isValid()) {
        m_sleepInhibitFd = reply.value();
        qDebug() << "patron-radio:" << "Sleep inhibit lock acquired";
    } else {
        qDebug() << "patron-radio:" << "Failed to acquire sleep inhibit lock:" << reply.error().message();
    }
}

void RadioBackend::releaseSleepInhibitLock()
{
    if (!m_sleepInhibitFd.isValid())
        return;
    m_sleepInhibitFd = QDBusUnixFileDescriptor(); // closes the fd
    qDebug() << "patron-radio:" << "Sleep inhibit lock released";
}

void RadioBackend::scheduleReconnect()
{
    if (!m_wantsToPlay || m_currentUrl.isEmpty() || m_reconnectTimer.isActive())
        return;

    if (m_reconnectAttempts >= RECONNECT_MAX_ATTEMPTS) {
        qDebug() << "patron-radio:" << "Reconnect limit reached (" << RECONNECT_MAX_ATTEMPTS << " attempts), giving up";
        m_wantsToPlay = false;
        // Surface the failure. A stall-triggered reconnect never set lastError,
        // so without this the UI would sit on the buffering spinner forever
        // instead of offering the "Fix" action.
        m_lastError = i18nd(PR_DOMAIN, "Stream unavailable after repeated reconnect attempts");
        Q_EMIT lastErrorChanged();
        if (m_buffering) {
            m_buffering = false;
            Q_EMIT bufferingChanged();
        }
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

    qDebug() << "patron-radio:" << "Scheduling reconnect in" << delay << "ms (base" << m_reconnectDelay << "+ jitter" << jitter << ")";
    m_reconnectTimer.start(delay);
}

void RadioBackend::attemptReconnect()
{
    if (!m_wantsToPlay || m_currentUrl.isEmpty())
        return;

    qDebug() << "patron-radio:" << "Attempting reconnect to" << m_currentUrl;
    m_stallTimer.stop();
    m_icyReader->stop();
    m_player->stop();
    m_player->setSource(QUrl());
    applyEffectiveVolume();

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
