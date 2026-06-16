#include "icystreamreader.h"
#include <QNetworkRequest>
#include <QMutexLocker>
#include <QThread>
#include <QHostAddress>
#include <QDebug>

// Pre-play buffer: aim for a fixed *duration* of audio (so start-up latency
// doesn't balloon on low-bitrate streams), sized from the station's advertised
// icy-br (assuming 128kbps when absent). A momentary underrun is harmless
// because readData() blocks for more data rather than signalling EOF.
static constexpr int READY_TARGET_MS = 2000;          // target pre-roll duration
static constexpr int ASSUMED_KBPS = 128;              // bitrate assumption when icy-br is absent
static constexpr int READY_FLOOR = 16 * 1024;         // never start the demuxer with less than this
static constexpr int MAX_BUFFER = 10 * 1024 * 1024;   // 10MB cap
static constexpr unsigned long READ_WAIT_MS = 8000;   // max blocking wait in readData() before yielding
static constexpr qint64 MAX_METAINT = 1024 * 1024;    // sane upper bound for icy-metaint (real values are a few KB)

IcyStreamReader::IcyStreamReader(QObject *parent)
    : QIODevice(parent), m_reply(nullptr), m_metaInt(0), m_audioBytesRead(0), m_metaBytesLeft(0), m_readyToPlayEmitted(false), m_readyThreshold(0), m_state(StateAudio)
{
    open(QIODevice::ReadOnly | QIODevice::Unbuffered);
}

IcyStreamReader::~IcyStreamReader()
{
    stop();
}

bool IcyStreamReader::isDisallowedUrl(const QUrl &url)
{
    const QString scheme = url.scheme().toLower();
    if (scheme != QLatin1String("http") && scheme != QLatin1String("https"))
        return true; // only fetch over http/https

    // If the host is a literal IP, require it to be globally routable. This blocks
    // SSRF to loopback/private/link-local/ULA/multicast (e.g. 127.0.0.1,
    // 169.254.169.254, 192.168.x.x). Hostnames that resolve to such addresses
    // aren't caught here (that needs DNS resolution); this covers the direct case.
    const QHostAddress addr(url.host());
    if (!addr.isNull() && !addr.isGlobal())
        return true;

    return false;
}

void IcyStreamReader::start(const QUrl &url)
{
    stop();

    if (isDisallowedUrl(url)) {
        qDebug() << "Refusing to open disallowed stream URL:" << url.toString();
        Q_EMIT errorOccurred(QStringLiteral("Refused an unsupported or non-routable stream URL"));
        return;
    }

    QNetworkRequest request(url);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setRawHeader("Icy-MetaData", "1");

    m_reply = m_nam.get(request);

    // Validate every redirect target too — the scheme/IP check above only covers
    // the initial URL, and a redirect could point at an internal host.
    connect(m_reply, &QNetworkReply::redirected, this, [this](const QUrl &target) {
        if (isDisallowedUrl(target)) {
            qDebug() << "Blocking redirect to disallowed host:" << target.toString();
            if (m_reply)
                m_reply->abort();
            Q_EMIT errorOccurred(QStringLiteral("Refused a redirect to a non-routable host"));
        }
    });

    {
        QMutexLocker locker(&m_bufferMutex);
        m_audioBuffer.clear();
        m_active = true;
    }
    m_metaBuffer.clear();
    m_audioBytesRead = 0;
    m_metaBytesLeft = 0;
    m_state = StateAudio;
    m_metaInt = 0;
    m_readyThreshold = 0; // recomputed from headers on first readyRead
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
    {
        QMutexLocker locker(&m_bufferMutex);
        m_audioBuffer.clear();
        m_active = false;
        m_dataReady.wakeAll(); // release any reader blocked in readData()
    }
    m_readyToPlayEmitted = false;
}

qint64 IcyStreamReader::readData(char *data, qint64 maxlen)
{
    QMutexLocker locker(&m_bufferMutex);
    // Block until audio is available instead of returning 0: the FFmpeg backend
    // (which calls this on its own worker thread) treats a 0-length read on a
    // live sequential source as end-of-stream, killing playback the first time
    // our buffer momentarily drains. Wait is bounded so a truly dead stream
    // still unblocks; the network error / stall watchdog handles real outages.
    //
    // CRITICAL: only block off our home thread. processData() refills the buffer
    // on the GUI thread, so if the framework ever reads on that same thread
    // (e.g. synchronous probing during play()), blocking would wait for a refill
    // that can never run — freezing the UI event loop. There we return what we
    // have (possibly 0) and let the backend retry.
    const bool canBlock = (QThread::currentThread() != thread());
    while (canBlock && m_active && m_audioBuffer.isEmpty()) {
        if (!m_dataReady.wait(&m_bufferMutex, READ_WAIT_MS))
            break; // timed out with no data — give the backend a 0 and let recovery kick in
    }

    qint64 bytesToRead = qMin((qint64)m_audioBuffer.size(), maxlen);
    if (bytesToRead > 0) {
        memcpy(data, m_audioBuffer.constData(), bytesToRead);
        m_audioBuffer.remove(0, bytesToRead);
        return bytesToRead;
    }
    return 0;
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
    QMutexLocker locker(&m_bufferMutex);
    return m_audioBuffer.size() + QIODevice::bytesAvailable();
}

bool IcyStreamReader::atEnd() const
{
    if (m_reply && !m_reply->isFinished()) {
        return false;
    }
    bool bufferEmpty;
    {
        QMutexLocker locker(&m_bufferMutex);
        bufferEmpty = m_audioBuffer.isEmpty();
    }
    // QIODevice::atEnd() calls the virtual bytesAvailable(), which re-locks the
    // mutex, so it must run *after* we release ours (the mutex is non-recursive).
    return bufferEmpty && QIODevice::atEnd();
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
        m_metaInt = -1; // default: treat as no metadata
        if (m_reply->hasRawHeader("icy-metaint")) {
            bool ok = false;
            const qint64 mi = m_reply->rawHeader("icy-metaint").trimmed().toLongLong(&ok);
            // Reject junk / absurd values from a hostile stream so the audio
            // counter can't run unbounded (and overflow).
            if (ok && mi > 0 && mi <= MAX_METAINT)
                m_metaInt = mi;
        }
    }

    if (m_readyThreshold == 0) {
        // icy-br is the stream bitrate in kbps (occasionally a comma list, e.g. "128,128").
        int br = 0;
        if (m_reply->hasRawHeader("icy-br"))
            br = m_reply->rawHeader("icy-br").split(',').first().trimmed().toInt();
        if (br <= 0)
            br = ASSUMED_KBPS;

        const qint64 bytesPerSec = (qint64)br * 1000 / 8;
        const qint64 threshold = bytesPerSec * READY_TARGET_MS / 1000;
        m_readyThreshold = (int)qBound((qint64)READY_FLOOR, threshold, (qint64)(MAX_BUFFER / 2));
        qDebug() << "IcyStreamReader pre-play threshold:" << m_readyThreshold
                 << "bytes (icy-br" << br << "kbps)";
    }

    processData();
}

void IcyStreamReader::processData()
{
    if (!m_reply) return;

    bool hasNewAudio = false;
    bool hasNewTitle = false;
    QString newTitle;
    int audioBufferSize = 0;

    // Hold the buffer lock only while touching m_audioBuffer; the title is
    // captured and signals are emitted *after* unlocking, because their slots
    // re-enter this device (readData on the backend thread, setSourceDevice in
    // the readyToPlay handler) and the mutex is non-recursive.
    {
        QMutexLocker locker(&m_bufferMutex);

        while (m_reply->bytesAvailable() > 0) {
            if (m_metaInt <= 0) {
                m_audioBuffer.append(m_reply->readAll());
                hasNewAudio = true;
                break;
            }

            if (m_state == StateAudio) {
                qint64 toRead = qMin(m_metaInt - m_audioBytesRead, m_reply->bytesAvailable());
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
                                hasNewTitle = true;
                                newTitle = title;
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
        audioBufferSize = m_audioBuffer.size();
        if (hasNewAudio)
            m_dataReady.wakeAll(); // unblock readData() waiting for audio
    }

    if (hasNewTitle) {
        Q_EMIT streamTitleChanged(newTitle);
    }

    if (hasNewAudio) {
        Q_EMIT readyRead();
    }

    // Defer handing the device over to QMediaPlayer until we have an initial buffer
    if (!m_readyToPlayEmitted && audioBufferSize > m_readyThreshold) {
        m_readyToPlayEmitted = true;
        Q_EMIT readyToPlay();
    }
}
