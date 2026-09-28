#include <QtTest>
#include <QSignalSpy>
#include "../src/icystreamreader.h"
#include "sharedvectors.h"

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
        QUrl url(QStringLiteral("http://radio.invalid/stream.mp3"));

        reader.start(url);
        QCOMPARE(reader.isActive(), true);

        reader.stop();
        QCOMPARE(reader.isActive(), false);
        QCOMPARE(reader.bytesAvailable(), (qint64)0);
    }

    void testStopClearsBuffer()
    {
        IcyStreamReader reader;
        reader.start(QUrl(QStringLiteral("http://radio.invalid/stream.mp3")));
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
        QUrl url(QStringLiteral("http://radio.invalid/stream.mp3"));

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

    // ---------------------------------------------------------------
    // HTML entity decoding — station playout chains often escape titles.
    // The cases live in tests/data/html_entities.json, shared with the
    // macOS app's tests so both decoders follow the same rules.
    // ---------------------------------------------------------------

    void testDecodeHtmlEntities_data()
    {
        QTest::addColumn<QString>("input");
        QTest::addColumn<QString>("expected");

        const QJsonArray cases = loadSharedCases(QStringLiteral("html_entities.json"));
        QVERIFY2(!cases.isEmpty(), "tests/data/html_entities.json is missing or empty");
        for (const QJsonValue &value : cases) {
            const QJsonObject c = value.toObject();
            QTest::newRow(qPrintable(c.value(QLatin1String("name")).toString()))
                << c.value(QLatin1String("input")).toString()
                << c.value(QLatin1String("expected")).toString();
        }
    }

    void testDecodeHtmlEntities()
    {
        QFETCH(QString, input);
        QFETCH(QString, expected);
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(input), expected);
    }
};

QTEST_GUILESS_MAIN(TestIcyStream)
#include "test_icystream.moc"
