#ifndef ICYSTREAMREADER_H
#define ICYSTREAMREADER_H

#include <QIODevice>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QByteArray>
#include <QUrl>
#include <QString>
#include <QMutex>

class IcyStreamReader : public QIODevice
{
    Q_OBJECT
public:
    explicit IcyStreamReader(QObject *parent = nullptr);
    ~IcyStreamReader();

    void start(const QUrl &url);
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

    int m_metaInt;
    int m_audioBytesRead;
    int m_metaBytesLeft;
    bool m_readyToPlayEmitted;

    enum State { StateAudio, StateMetaLength, StateMetaData } m_state;
    QByteArray m_metaBuffer;
    QString m_lastTitle;
};

#endif // ICYSTREAMREADER_H
