#include <QtTest>
#include <QSignalSpy>
#include "../src/icystreamreader.h"

class TestIcyStream : public QObject
{
    Q_OBJECT

private Q_SLOTS:
    void testInitialState()
    {
        IcyStreamReader reader;
        QCOMPARE(reader.isOpen(), true);
        QCOMPARE(reader.isSequential(), true);
        QCOMPARE(reader.isActive(), false);
        QCOMPARE(reader.bytesAvailable(), (qint64)0);
    }

    void testStartStop()
    {
        IcyStreamReader reader;
        QUrl url(QStringLiteral("http://example.com/stream.mp3"));

        reader.start(url);
        QCOMPARE(reader.isActive(), true);

        reader.stop();
        QCOMPARE(reader.isActive(), false);
        QCOMPARE(reader.bytesAvailable(), (qint64)0);
    }

    void testStopClearsBuffer()
    {
        IcyStreamReader reader;
        reader.start(QUrl(QStringLiteral("http://example.com/stream.mp3")));
        QCOMPARE(reader.isActive(), true);

        reader.stop();
        QCOMPARE(reader.isActive(), false);
        QCOMPARE(reader.bytesAvailable(), (qint64)0);
    }

    void testDoubleStopIsSafe()
    {
        IcyStreamReader reader;
        reader.stop();
        reader.stop();
        QCOMPARE(reader.isActive(), false);
    }

    void testRestartClearsState()
    {
        IcyStreamReader reader;
        QUrl url(QStringLiteral("http://example.com/stream.mp3"));

        reader.start(url);
        QCOMPARE(reader.isActive(), true);

        // Restarting should stop old and start new
        reader.start(url);
        QCOMPARE(reader.isActive(), true);

        reader.stop();
        QCOMPARE(reader.isActive(), false);
    }

    void testAtEndWhenInactive()
    {
        IcyStreamReader reader;
        QCOMPARE(reader.atEnd(), true);
    }

    void testReadDataReturnsZeroWhenEmpty()
    {
        IcyStreamReader reader;
        char buf[64];
        qint64 read = reader.readData(buf, sizeof(buf));
        QCOMPARE(read, (qint64)0);
    }

    void testErrorSignalExists()
    {
        IcyStreamReader reader;
        QSignalSpy spy(&reader, &IcyStreamReader::errorOccurred);
        QVERIFY(spy.isValid());
    }

    void testReadyToPlaySignalExists()
    {
        IcyStreamReader reader;
        QSignalSpy spy(&reader, &IcyStreamReader::readyToPlay);
        QVERIFY(spy.isValid());
    }

    void testStreamTitleChangedSignalExists()
    {
        IcyStreamReader reader;
        QSignalSpy spy(&reader, &IcyStreamReader::streamTitleChanged);
        QVERIFY(spy.isValid());
    }
};

QTEST_GUILESS_MAIN(TestIcyStream)
#include "test_icystream.moc"
