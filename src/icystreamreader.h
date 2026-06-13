#ifndef ICYSTREAMREADER_H
#define ICYSTREAMREADER_H

#include <QIODevice>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QByteArray>
#include <QUrl>
#include <QString>
#include <QMutex>
#include <QWaitCondition>

class IcyStreamReader : public QIODevice
{
    Q_OBJECT
public:
    explicit IcyStreamReader(QObject *parent = nullptr);
    ~IcyStreamReader();

    // targetMs is the desired pre-roll duration before playback begins; pass 0
    // to use the default. Larger values trade start-up latency for underrun
    // resilience (see RadioBackend's escalating retry).
    void start(const QUrl &url, int targetMs = 0);
    void stop();
    bool isActive() const { return m_reply != nullptr; }

    qint64 readData(char *data, qint64 maxlen) override;
    qint64 writeData(const char *data, qint64 len) override;
    bool isSequential() const override;
    qint64 bytesAvailable() const override;
    bool atEnd() const override;

Q_SIGNALS:
    void streamTitleChanged(const QString &title);
    void readyToPlay();
    void errorOccurred(const QString &errorString);

private Q_SLOTS:
    void onReadyRead();
    void onFinished();

private:
    void processData();

    QNetworkAccessManager m_nam;
    QNetworkReply *m_reply;

    // m_audioBuffer is produced on the thread that drives processData() (the
    // main/GUI thread, via the reply's readyRead signal) and consumed from the
    // QtMultimedia backend thread through readData(). All access must hold the
    // mutex. mutable so the const query overrides can lock it.
    QByteArray m_audioBuffer;
    mutable QMutex m_bufferMutex;
    // readData() (backend thread) blocks on this until processData() (GUI
    // thread) delivers more audio, rather than returning 0 — the FFmpeg backend
    // mis-reads a 0-length read on a live sequential source as end-of-stream.
    QWaitCondition m_dataReady;
    bool m_active = false;          // true between start() and stop(); guarded by m_bufferMutex

    int m_metaInt;
    int m_audioBytesRead;
    int m_metaBytesLeft;
    bool m_readyToPlayEmitted;
    int m_readyThreshold;   // bytes of audio to pre-buffer before play; from icy-br or fallback
    int m_targetMs;         // desired pre-roll duration; set per start()

    enum State { StateAudio, StateMetaLength, StateMetaData } m_state;
    QByteArray m_metaBuffer;
    QString m_lastTitle;
};

#endif // ICYSTREAMREADER_H
