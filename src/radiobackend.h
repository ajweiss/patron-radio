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
#include <limits>

#include "icystreamreader.h"

class QAudioBufferOutput;
class QAudioBuffer;

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
    Q_PROPERTY(bool normalizeLoudness READ normalizeLoudness WRITE setNormalizeLoudness NOTIFY normalizeLoudnessChanged)
    // knownLoudness: QML seeds this (LUFS, NaN if unknown) before switching station
    // so a previously-measured station starts at the right level instantly.
    // measuredLoudness: the live estimate QML reads back and persists per station.
    Q_PROPERTY(double knownLoudness READ knownLoudness WRITE setKnownLoudness)
    Q_PROPERTY(double measuredLoudness READ measuredLoudness NOTIFY measuredLoudnessChanged)
    Q_PROPERTY(double loudnessTarget READ loudnessTarget CONSTANT) // normalization target (LUFS)
    // When false, levels aren't measured — stored/manual loudness values are applied but never overwritten.
    Q_PROPERTY(bool loudnessAuto READ loudnessAuto WRITE setLoudnessAuto NOTIFY loudnessAutoChanged)
    // Cross-instance station-list sync. The backend is a singleton shared by every
    // applet instance in the same process, so it doubles as a broadcast bus: an
    // instance writes a user-edited station list here and the others adopt it.
    // KConfig stays each instance's persistent cache. Holds the stations JSON.
    Q_PROPERTY(QString sharedStations READ sharedStations WRITE setSharedStations NOTIFY sharedStationsChanged)
    // Same bus for the toggles that govern the (shared) backend — normalization,
    // loudness auto-learn, sleep inhibit. Holds a small JSON blob of those values.
    Q_PROPERTY(QString sharedSettings READ sharedSettings WRITE setSharedSettings NOTIFY sharedSettingsChanged)

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
    ~RadioBackend() override;

    bool normalizeLoudness() const { return m_normalizeLoudness; }
    void setNormalizeLoudness(bool on);

    double knownLoudness() const { return m_seedLoudness; }
    void setKnownLoudness(double lufs) { m_seedLoudness = lufs; } // applied at next stream start
    double measuredLoudness() const { return m_measuredLoudness; }
    double loudnessTarget() const { return LOUDNESS_TARGET_LUFS; }
    bool loudnessAuto() const { return m_loudnessAuto; }
    void setLoudnessAuto(bool on);

    QString sharedStations() const { return m_sharedStations; }
    void setSharedStations(const QString &json);

    QString sharedSettings() const { return m_sharedSettings; }
    void setSharedSettings(const QString &json);

    // Loudness math, factored out as pure functions so they can be unit-tested
    // without an audio pipeline. attenuationGainDb returns the gain (always <= 0,
    // i.e. attenuation only — QAudioOutput can't amplify past the user's volume)
    // needed to bring measuredLufs down to targetLufs, clamped to a safe range.
    static double attenuationGainDb(double measuredLufs, double targetLufs);
    static bool loudnessMeasurable(double lufs); // false for silence / non-finite

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
        applyEffectiveVolume(); // honour the loudness-normalization gain
        QVariantMap changed;
        changed[QStringLiteral("Volume")] = m_volume;
        emitMprisPropertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), changed);
    }

    // Resolve a plain-text query into the user's configured default search
    // engine (KDE web shortcuts). Returns "" if none is available; QML then
    // falls back to a built-in provider. http(s) result only.
    Q_INVOKABLE QString webSearchUrl(const QString &query) const;

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
    void normalizeLoudnessChanged();
    void measuredLoudnessChanged();
    void loudnessAutoChanged();
    void sharedStationsChanged();
    void sharedSettingsChanged();

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

    // Loudness normalization (EBU R128). We tap decoded PCM via QAudioBufferOutput,
    // measure short-term loudness with libebur128, and attenuate the output toward
    // a target LUFS. Attenuation only: louder stations are pulled down to match,
    // quieter ones are left as-is (the master volume can't exceed 1.0).
    QAudioBufferOutput *m_audioBufferOutput = nullptr;
    void *m_ebur128State = nullptr;   // opaque ebur128_state* (kept out of the header)
    int m_eburChannels = 0;
    int m_eburRate = 0;
    double m_normGainDb = 0.0;        // currently applied attenuation, <= 0
    bool m_normalizeLoudness = true;
    bool m_loudnessAuto = true;       // measure & refine loudness vs. apply stored values only
    QString m_sharedStations;         // last station list broadcast across instances
    QString m_sharedSettings;         // last backend-toggle blob broadcast across instances
    QTimer m_loudnessTimer;
    static constexpr double kNaN = std::numeric_limits<double>::quiet_NaN();
    double m_seedLoudness = kNaN;        // last-known loudness for the current station (from config)
    double m_measuredLoudness = kNaN;    // live estimate (EMA), exposed to QML for persistence
    double m_lastEmittedLoudness = kNaN; // throttles measuredLoudnessChanged
    // EBU R128 broadcast reference. Deliberately low so nearly every station
    // sits above it and can be normalized *down* to match (we can only attenuate).
    static constexpr double LOUDNESS_TARGET_LUFS = -23.0;
    // Assumed level for a not-yet-measured station, so it starts pre-attenuated
    // instead of blasting at full volume until the meter converges.
    static constexpr double LOUDNESS_DEFAULT_LUFS = -16.0;
    static constexpr double LOUDNESS_MAX_ATTEN_DB = 24.0;
    static constexpr double LOUDNESS_SLEW_DB_PER_TICK = 1.0; // limits how fast gain moves -> no pumping
    static constexpr int LOUDNESS_TICK_MS = 400;

    void onAudioBuffer(const QAudioBuffer &buffer);
    void updateNormalizationGain();
    void applyEffectiveVolume();
    void freeMeter();        // destroy the ebur128 meter (leaves gain untouched)
    void beginStreamLoudness(); // free meter + seed gain from m_seedLoudness for a new station

    void emitMprisPropertiesChanged(const QString &interface, const QVariantMap &changedProperties);
    void takeSleepInhibitLock();
    void releaseSleepInhibitLock();
    void scheduleReconnect();
    void attemptReconnect();
};

#endif // RADIOBACKEND_H
