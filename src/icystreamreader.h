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

    void start(const QUrl &url);
    void stop();
    bool isActive() const { return m_reply != nullptr; }

    // Station playout chains often HTML-escape titles somewhere between the
    // automation system and the encoder, so "Simon & Garfunkel" arrives as
    // "Simon &amp; Garfunkel". Decodes the handful of named entities escapers
    // actually emit plus numeric references; anything unrecognized is left
    // untouched. Deliberately not an HTML parser (untrusted input). Single
    // pass. Public and static so it can be unit-tested directly.
    static QString decodeHtmlEntities(const QString &text);

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
    // Reject non-http(s) schemes and literal IPs that aren't globally routable
    // (loopback/private/link-local/etc.) to limit SSRF from untrusted stream URLs.
    static bool isDisallowedUrl(const QUrl &url);

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
    // Mirrors m_reply's finished state for atEnd(), which the QtMultimedia
    // backend calls on its worker thread — it must not touch m_reply itself
    // (created/aborted/nulled on the GUI thread). Guarded by m_bufferMutex.
    bool m_replyFinished = true;

    qint64 m_metaInt;        // ICY metadata interval (bytes); -1 = none/invalid. 64-bit: hostile headers
    qint64 m_audioBytesRead; // running count toward m_metaInt — guard against signed overflow
    int m_metaBytesLeft;
    bool m_readyToPlayEmitted;
    int m_readyThreshold;   // bytes of audio to pre-buffer before play; from icy-br or fallback

    enum State { StateAudio, StateMetaLength, StateMetaData } m_state;
    QByteArray m_metaBuffer;
    QString m_lastTitle;
};

#endif // ICYSTREAMREADER_H
