#ifndef RADIOBACKEND_H
#define RADIOBACKEND_H

#include <QObject>
#include <QMediaPlayer>
#include <QAudioOutput>
#include <QtQml/qqml.h>
#include <QVariantMap>
#include <QDBusObjectPath>
#include <QMediaDevices>
#include <QAudioDevice>
#include <QDBusUnixFileDescriptor>
#include <QTimer>

#include "icystreamreader.h"

class RadioBackend : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2")
    
    // QML Properties
    Q_PROPERTY(bool playing READ isPlaying NOTIFY playingChanged)
    Q_PROPERTY(bool buffering READ isBuffering NOTIFY bufferingChanged)
    Q_PROPERTY(QString streamTitle READ streamTitle NOTIFY streamTitleChanged)
    Q_PROPERTY(QString currentStationName READ currentStationName WRITE setCurrentStationName NOTIFY currentStationNameChanged)
    Q_PROPERTY(QString currentUrl READ currentUrl WRITE setCurrentUrl NOTIFY currentUrlChanged)
    Q_PROPERTY(QVariantList availableOutputs READ availableOutputs NOTIFY availableOutputsChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
    Q_PROPERTY(bool inhibitSleep READ inhibitSleep WRITE setInhibitSleep NOTIFY inhibitSleepChanged)
    
    QML_ELEMENT
    QML_SINGLETON

    // MPRIS Root Properties
    Q_PROPERTY(bool CanQuit READ CanQuit)
    Q_PROPERTY(bool CanRaise READ CanRaise)
    Q_PROPERTY(bool HasTrackList READ HasTrackList)
    Q_PROPERTY(QString Identity READ Identity)
    Q_PROPERTY(QString DesktopEntry READ DesktopEntry)
    Q_PROPERTY(QStringList SupportedUriSchemes READ SupportedUriSchemes)
    Q_PROPERTY(QStringList SupportedMimeTypes READ SupportedMimeTypes)

    // MPRIS Player Properties
    Q_PROPERTY(QString PlaybackStatus READ PlaybackStatus)
    Q_PROPERTY(QString LoopStatus READ LoopStatus WRITE SetLoopStatus)
    Q_PROPERTY(double Rate READ Rate WRITE SetRate)
    Q_PROPERTY(QVariantMap Metadata READ Metadata)
    Q_PROPERTY(double Volume READ Volume WRITE SetVolume)
    Q_PROPERTY(qlonglong Position READ Position)
    Q_PROPERTY(bool CanGoNext READ CanGoNext)
    Q_PROPERTY(bool CanGoPrevious READ CanGoPrevious)
    Q_PROPERTY(bool CanPlay READ CanPlay)
    Q_PROPERTY(bool CanPause READ CanPause)
    Q_PROPERTY(bool CanSeek READ CanSeek)
    Q_PROPERTY(bool CanControl READ CanControl)

public:
    explicit RadioBackend(QObject *parent = nullptr);

    bool isPlaying() const;
    bool isBuffering() const;
    QString streamTitle() const;
    QString currentStationName() const;
    void setCurrentStationName(const QString &name);
    QString currentUrl() const;
    void setCurrentUrl(const QString &url);
    QVariantList availableOutputs() const;
    QString lastError() const;
    bool inhibitSleep() const;
    void setInhibitSleep(bool inhibit);

    // MPRIS Player Getters
    QString PlaybackStatus() const;
    QString LoopStatus() const { return QStringLiteral("None"); }
    double Rate() const { return 1.0; }
    QVariantMap Metadata() const;
    double Volume() const { return m_volume; }
    qlonglong Position() const { return 0; } // Live streams don't really have a position
    bool CanGoNext() const { return true; }
    bool CanGoPrevious() const { return true; }
    bool CanPlay() const { return true; }
    bool CanPause() const { return true; }
    bool CanSeek() const { return false; }
    bool CanControl() const { return true; }

    // MPRIS Root Getters
    bool CanQuit() const { return false; }
    bool CanRaise() const { return false; }
    bool HasTrackList() const { return false; }
    QString Identity() const { return QStringLiteral("Patron Radio"); }
    QString DesktopEntry() const { return QStringLiteral("com.signal11.patronradio"); }
    QStringList SupportedUriSchemes() const { return {QStringLiteral("http"), QStringLiteral("https")}; }
    QStringList SupportedMimeTypes() const { return {QStringLiteral("audio/mpeg"), QStringLiteral("audio/aac"), QStringLiteral("audio/ogg"), QStringLiteral("audio/x-scpls")}; }

    // MPRIS Player Setters
    void SetLoopStatus(const QString &) {}
    void SetRate(double ) {}
    void SetVolume(double v) {
        m_volume = v;
        m_audioOutput->setVolume(v);
        QVariantMap changed;
        changed[QStringLiteral("Volume")] = m_volume;
        emitMprisPropertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), changed);
    }

public:
    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE bool routeAudioToBluetooth(const QString &macAddress);
    Q_INVOKABLE void setAudioOutput(const QString &deviceId);
    Q_INVOKABLE void resetAudioOutput();

    // MPRIS Root Methods
    void Raise() {}
    void Quit() {}

    // MPRIS Player Methods
    void Next() { Q_EMIT nextRequested(); }
    void Previous() { Q_EMIT previousRequested(); }
    void Pause() { stop(); }  // For live streams, pause = stop (no buffering a live feed)
    void PlayPause() { if(isPlaying()) stop(); else play(); }
    void Stop() { stop(); }
    void Play() { play(); }
    void Seek(qlonglong) {}
    void SetPosition(const QDBusObjectPath &, qlonglong) {}
    void OpenUri(const QString &uri) { setCurrentUrl(uri); play(); }

Q_SIGNALS:
    void playingChanged();
    void bufferingChanged();
    void streamTitleChanged();
    void currentStationNameChanged();
    void currentUrlChanged();
    void availableOutputsChanged();
    void lastErrorChanged();
    void inhibitSleepChanged();
    void nextRequested();
    void previousRequested();

private:
    QMediaPlayer *m_player;
    QAudioOutput *m_audioOutput;
    IcyStreamReader *m_icyReader;

    bool m_playing = false;
    bool m_buffering = false;
    QString m_streamTitle;
    QString m_currentStationName;
    QString m_currentUrl;
    QString m_lastError;
    double m_volume = 1.0;
    bool m_inhibitSleep = false;
    QDBusUnixFileDescriptor m_sleepInhibitFd;

    QTimer m_reconnectTimer;
    int m_reconnectDelay = 0;
    int m_reconnectAttempts = 0;
    bool m_wantsToPlay = false;
    static constexpr int RECONNECT_INITIAL_MS = 2000;
    static constexpr int RECONNECT_MAX_MS = 30000;
    static constexpr int RECONNECT_MAX_ATTEMPTS = 10;

    // Watchdog for buffer underruns: QMediaPlayer's backend can stall on a
    // starved source device and never recover on its own, so if it stays
    // stalled/re-buffering past this timeout we force a clean reconnect.
    QTimer m_stallTimer;
    static constexpr int STALL_TIMEOUT_MS = 7000;

    // Adaptive pre-roll: start streams thin for a fast start, and if they keep
    // underrunning, escalate the pre-buffer duration on each stall-reconnect
    // until playback holds. Reset to the initial value on stop / station change.
    static constexpr int PREROLL_INITIAL_MS = 2000;
    static constexpr int PREROLL_MAX_MS = 16000;
    int m_prerollMs = PREROLL_INITIAL_MS;

    void emitMprisPropertiesChanged(const QString &interface, const QVariantMap &changedProperties);
    void takeSleepInhibitLock();
    void releaseSleepInhibitLock();
    void scheduleReconnect();
    void attemptReconnect();
};

#endif // RADIOBACKEND_H
