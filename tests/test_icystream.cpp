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
    // HTML entity decoding — station playout chains often escape titles
    // ---------------------------------------------------------------

    void testDecodeNamedEntities()
    {
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("Simon &amp; Garfunkel")),
                 QStringLiteral("Simon & Garfunkel"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("&lt;3 Deluxe &gt;&gt;")),
                 QStringLiteral("<3 Deluxe >>"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("&quot;Heroes&quot;")),
                 QStringLiteral("\"Heroes\""));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("Guns N&apos; Roses")),
                 QStringLiteral("Guns N' Roses"));
        // nbsp is normalized to a plain space.
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("A&nbsp;B")),
                 QStringLiteral("A B"));
    }

    void testDecodeNumericEntities()
    {
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("Don&#39;t Stop")),
                 QStringLiteral("Don't Stop"));
        // Curly apostrophe, decimal and hex forms.
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("It&#8217;s Oh So Quiet")),
                 QString::fromUtf8("It\xE2\x80\x99s Oh So Quiet"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("It&#x2019;s")),
                 QString::fromUtf8("It\xE2\x80\x99s"));
        // Astral-plane code point (emoji) must come out as a surrogate pair.
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("Party &#128512;")),
                 QString::fromUtf8("Party \xF0\x9F\x98\x80"));
    }

    void testDecodeLeavesLiteralsAlone()
    {
        // Plain ampersands, with and without a distant semicolon in the text.
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("AC & DC")),
                 QStringLiteral("AC & DC"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("Mumford & Sons; Live")),
                 QStringLiteral("Mumford & Sons; Live"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("Rock &")),
                 QStringLiteral("Rock &"));
        // Unknown or malformed entities pass through untouched.
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("&foo;")),
                 QStringLiteral("&foo;"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("&#;")),
                 QStringLiteral("&#;"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("&#x;")),
                 QStringLiteral("&#x;"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("&# 39;")),
                 QStringLiteral("&# 39;"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QString()),
                 QString());
    }

    void testDecodeRejectsUnsafeCodePoints()
    {
        // Controls, surrogate halves, and out-of-range values stay literal.
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("&#0;")),
                 QStringLiteral("&#0;"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("&#31;")),
                 QStringLiteral("&#31;"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("&#x9F;")),
                 QStringLiteral("&#x9F;"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("&#xD800;")),
                 QStringLiteral("&#xD800;"));
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("&#1114112;")), // 0x110000
                 QStringLiteral("&#1114112;"));
    }

    void testDecodeIsSinglePass()
    {
        // A double-escaped title decodes one level per arrival; we do not
        // iterate to a fixpoint because that would mangle titles that
        // legitimately contain entity-looking text.
        QCOMPARE(IcyStreamReader::decodeHtmlEntities(QStringLiteral("Me &amp;amp; You")),
                 QStringLiteral("Me &amp; You"));
    }
};

QTEST_GUILESS_MAIN(TestIcyStream)
#include "test_icystream.moc"
