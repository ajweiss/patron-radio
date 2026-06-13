#include "icystreamreader.h"
#include <QNetworkRequest>
#include <QDebug>

static constexpr int READY_THRESHOLD = 128 * 1024;   // 128KB before playback
static constexpr int MAX_BUFFER = 10 * 1024 * 1024;  // 10MB cap

IcyStreamReader::IcyStreamReader(QObject *parent)
    : QIODevice(parent), m_reply(nullptr), m_metaInt(0), m_audioBytesRead(0), m_metaBytesLeft(0), m_readyToPlayEmitted(false), m_state(StateAudio)
{
    open(QIODevice::ReadOnly | QIODevice::Unbuffered);
}

IcyStreamReader::~IcyStreamReader()
{
    stop();
}

void IcyStreamReader::start(const QUrl &url)
{
    stop();

    QNetworkRequest request(url);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setRawHeader("Icy-MetaData", "1");

    m_reply = m_nam.get(request);

    m_audioBuffer.clear();
    m_metaBuffer.clear();
    m_audioBytesRead = 0;
    m_metaBytesLeft = 0;
    m_state = StateAudio;
    m_metaInt = 0;
    m_lastTitle.clear();
    m_readyToPlayEmitted = false;

    connect(m_reply, &QNetworkReply::readyRead, this, &IcyStreamReader::onReadyRead);
    connect(m_reply, &QNetworkReply::finished, this, &IcyStreamReader::onFinished);
}

void IcyStreamReader::stop()
{
    if (m_reply) {
        m_reply->abort();
        m_reply->deleteLater();
        m_reply = nullptr;
    }
    m_audioBuffer.clear();
    m_readyToPlayEmitted = false;
}

qint64 IcyStreamReader::readData(char *data, qint64 maxlen)
{
    qint64 bytesToRead = qMin((qint64)m_audioBuffer.size(), maxlen);
    if (bytesToRead > 0) {
        memcpy(data, m_audioBuffer.constData(), bytesToRead);
        m_audioBuffer.remove(0, bytesToRead);
        return bytesToRead;
    }
    return 0; // Returning 0 is proper non-blocking "no data right now"
}

qint64 IcyStreamReader::writeData(const char *, qint64)
{
    return -1; // Read-only
}

bool IcyStreamReader::isSequential() const
{
    return true;
}

qint64 IcyStreamReader::bytesAvailable() const
{
    return m_audioBuffer.size() + QIODevice::bytesAvailable();
}

bool IcyStreamReader::atEnd() const
{
    if (m_reply && !m_reply->isFinished()) {
        return false;
    }
    return m_audioBuffer.isEmpty() && QIODevice::atEnd();
}

void IcyStreamReader::onFinished()
{
    if (m_reply && m_reply->error() != QNetworkReply::NoError && m_reply->error() != QNetworkReply::OperationCanceledError) {
        QString err = m_reply->errorString();
        qDebug() << "IcyStreamReader network error:" << err;
        Q_EMIT errorOccurred(err);
    }
}

void IcyStreamReader::onReadyRead()
{
    if (!m_reply) return;

    if (m_metaInt == 0) {
        if (m_reply->hasRawHeader("icy-metaint")) {
            m_metaInt = m_reply->rawHeader("icy-metaint").toInt();
        } else {
            m_metaInt = -1;
        }
    }

    processData();
}

void IcyStreamReader::processData()
{
    if (!m_reply) return;

    bool hasNewAudio = false;

    while (m_reply->bytesAvailable() > 0) {
        if (m_metaInt <= 0) {
            m_audioBuffer.append(m_reply->readAll());
            hasNewAudio = true;
            break;
        }

        if (m_state == StateAudio) {
            qint64 toRead = qMin((qint64)(m_metaInt - m_audioBytesRead), m_reply->bytesAvailable());
            if (toRead > 0) {
                QByteArray audioChunk = m_reply->read(toRead);
                m_audioBuffer.append(audioChunk);
                m_audioBytesRead += audioChunk.size();
                hasNewAudio = true;
            }

            if (m_audioBytesRead == m_metaInt) {
                m_state = StateMetaLength;
                m_audioBytesRead = 0;
            }
        } else if (m_state == StateMetaLength) {
            char lengthByte;
            if (m_reply->read(&lengthByte, 1) == 1) {
                m_metaBytesLeft = static_cast<unsigned char>(lengthByte) * 16;
                if (m_metaBytesLeft > 0) {
                    m_state = StateMetaData;
                    m_metaBuffer.clear();
                } else {
                    m_state = StateAudio;
                }
            }
        } else if (m_state == StateMetaData) {
            qint64 toRead = qMin((qint64)m_metaBytesLeft, m_reply->bytesAvailable());
            if (toRead > 0) {
                QByteArray metaChunk = m_reply->read(toRead);
                m_metaBuffer.append(metaChunk);
                m_metaBytesLeft -= metaChunk.size();
            }

            if (m_metaBytesLeft == 0) {
                QString metaStr = QString::fromUtf8(m_metaBuffer);
                int titleStart = metaStr.indexOf(QStringLiteral("StreamTitle='"));
                if (titleStart != -1) {
                    titleStart += 13;
                    int titleEnd = metaStr.indexOf(QStringLiteral("';"), titleStart);
                    if (titleEnd != -1) {
                        QString title = metaStr.mid(titleStart, titleEnd - titleStart);
                        if (title != m_lastTitle) {
                            m_lastTitle = title;
                            Q_EMIT streamTitleChanged(title);
                        }
                    }
                }
                m_state = StateAudio;
            }
        }
    }

    if (m_audioBuffer.size() > MAX_BUFFER) {
        m_audioBuffer.remove(0, m_audioBuffer.size() - MAX_BUFFER);
    }

    if (hasNewAudio) {
        Q_EMIT readyRead();
    }
    
    // Defer handing the device over to QMediaPlayer until we have an initial buffer
    if (!m_readyToPlayEmitted && m_audioBuffer.size() > READY_THRESHOLD) {
        m_readyToPlayEmitted = true;
        Q_EMIT readyToPlay();
    }
}
