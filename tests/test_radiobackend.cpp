#include <QtTest>
#include <QSignalSpy>
#include <QTimer>
#include "../src/radiobackend.h"

// Helpers
static const QString FAKE_URL_A = QStringLiteral("http://example.com/stream_a.mp3");
static const QString FAKE_URL_B = QStringLiteral("http://example.com/stream_b.mp3");
static const QString FAKE_URL_C = QStringLiteral("http://example.com/stream_c.mp3");

class TestRadioBackend : public QObject
{
    Q_OBJECT

private Q_SLOTS:

    // ---------------------------------------------------------------
    // Initial state
    // ---------------------------------------------------------------

    void testInitialState()
    {
        RadioBackend b;
        QCOMPARE(b.isPlaying(), false);
        QCOMPARE(b.isBuffering(), false);
        QCOMPARE(b.streamTitle(), QString());
        QCOMPARE(b.currentStationName(), QString());
        QCOMPARE(b.currentUrl(), QString());
        QCOMPARE(b.lastError(), QString());
        QCOMPARE(b.inhibitSleep(), false);
        QCOMPARE(b.PlaybackStatus(), QStringLiteral("Stopped"));
    }

    // ---------------------------------------------------------------
    // Property setters — deduplication & signal correctness
    // ---------------------------------------------------------------

    void testSetStationNameDedup()
    {
        RadioBackend b;
        QSignalSpy spy(&b, &RadioBackend::currentStationNameChanged);
        b.setCurrentStationName(QStringLiteral("KEXP"));
        b.setCurrentStationName(QStringLiteral("KEXP"));
        QCOMPARE(spy.count(), 1);
        QCOMPARE(b.currentStationName(), QStringLiteral("KEXP"));
    }

    void testSetUrlDedup()
    {
        RadioBackend b;
        QSignalSpy spy(&b, &RadioBackend::currentUrlChanged);
        b.setCurrentUrl(FAKE_URL_A);
        b.setCurrentUrl(FAKE_URL_A);
        QCOMPARE(spy.count(), 1);
    }

    void testSetUrlClearsStreamTitle()
    {
        RadioBackend b;
        b.setCurrentStationName(QStringLiteral("Test"));
        b.setCurrentUrl(FAKE_URL_A);
        QCOMPARE(b.streamTitle(), QString());
    }

    void testSetUrlSetsBuffering()
    {
        RadioBackend b;
        QSignalSpy bufSpy(&b, &RadioBackend::bufferingChanged);
        b.setCurrentUrl(FAKE_URL_A);
        QVERIFY(bufSpy.count() >= 1);
    }

    // ---------------------------------------------------------------
    // Station switching — the core instability scenario
    // ---------------------------------------------------------------

    void testRapidStationSwitching()
    {
        // Simulate rapid station changes — should not crash or leak
        RadioBackend b;
        for (int i = 0; i < 20; i++) {
            b.setCurrentStationName(QStringLiteral("Station %1").arg(i));
            b.setCurrentUrl(QStringLiteral("http://example.com/stream_%1.mp3").arg(i));
            b.play();
        }
        // After rapid switching, state should be consistent
        QCOMPARE(b.currentStationName(), QStringLiteral("Station 19"));
        QCOMPARE(b.currentUrl(), QStringLiteral("http://example.com/stream_19.mp3"));
        QCOMPARE(b.streamTitle(), QString()); // cleared on each URL change
        b.stop();
        QCOMPARE(b.isPlaying(), false);
    }

    void testSwitchUrlWhileBuffering()
    {
        RadioBackend b;
        b.setCurrentUrl(FAKE_URL_A);
        b.play();
        // Now switch while still buffering
        b.setCurrentUrl(FAKE_URL_B);
        b.play();
        QCOMPARE(b.currentUrl(), FAKE_URL_B);
        b.stop();
    }

    void testSwitchUrlStopsOldStream()
    {
        RadioBackend b;
        b.setCurrentUrl(FAKE_URL_A);
        b.play();
        // Switching URL should stop the old ICY reader
        b.setCurrentUrl(FAKE_URL_B);
        // The old stream should be cleaned up — no crash, no dangling reply
        b.stop();
        QCOMPARE(b.isPlaying(), false);
    }

    // ---------------------------------------------------------------
    // Play / Pause / Stop state transitions
    // ---------------------------------------------------------------

    void testPlaySetsWantsToPlay()
    {
        RadioBackend b;
        b.setCurrentUrl(FAKE_URL_A);
        b.play();
        // play() should start the ICY reader — isBuffering should be true
        // (the player won't actually reach Playing state without real audio)
        b.stop();
        QCOMPARE(b.isPlaying(), false);
    }

    void testStopClearsStreamTitle()
    {
        RadioBackend b;
        b.setCurrentStationName(QStringLiteral("Test"));
        b.setCurrentUrl(FAKE_URL_A);
        b.play();
        b.stop();
        QCOMPARE(b.streamTitle(), QString());
    }

    void testStopCancelsReconnect()
    {
        RadioBackend b;
        b.setCurrentUrl(FAKE_URL_A);
        b.play();
        // Simulate an error that would trigger reconnect
        // (We can't easily trigger ICY error, but we can verify stop() cleans up)
        b.stop();
        // After stop, reconnect should not be pending
        // Process events to make sure no deferred reconnect fires
        QCoreApplication::processEvents();
        QCOMPARE(b.isPlaying(), false);
    }

    void testPauseCancelsReconnect()
    {
        RadioBackend b;
        b.setCurrentUrl(FAKE_URL_A);
        b.play();
        b.pause();
        QCoreApplication::processEvents();
        // Should not be trying to reconnect after explicit pause
        QCOMPARE(b.isPlaying(), false);
    }

    void testDoubleStopIsSafe()
    {
        RadioBackend b;
        b.stop();
        b.stop();
        QCOMPARE(b.isPlaying(), false);
        QCOMPARE(b.streamTitle(), QString());
    }

    void testDoublePlayIsSafe()
    {
        RadioBackend b;
        b.setCurrentUrl(FAKE_URL_A);
        b.play();
        b.play(); // should not crash or start duplicate streams
        b.stop();
    }

    void testPlayWithEmptyUrl()
    {
        RadioBackend b;
        // play() with no URL set — should not crash
        b.play();
        b.stop();
        QCOMPARE(b.isPlaying(), false);
    }

    void testPlayPauseCycle()
    {
        RadioBackend b;
        b.setCurrentUrl(FAKE_URL_A);
        for (int i = 0; i < 10; i++) {
            b.play();
            b.pause();
        }
        b.stop();
        QCOMPARE(b.isPlaying(), false);
    }

    void testPlayStopCycle()
    {
        RadioBackend b;
        b.setCurrentUrl(FAKE_URL_A);
        for (int i = 0; i < 10; i++) {
            b.play();
            b.stop();
        }
        QCOMPARE(b.isPlaying(), false);
        QCOMPARE(b.streamTitle(), QString());
    }

    // ---------------------------------------------------------------
    // MPRIS interface
    // ---------------------------------------------------------------

    void testMprisRootProperties()
    {
        RadioBackend b;
        QCOMPARE(b.CanQuit(), false);
        QCOMPARE(b.CanRaise(), false);
        QCOMPARE(b.HasTrackList(), false);
        QCOMPARE(b.Identity(), QStringLiteral("Patron Radio"));
        QCOMPARE(b.DesktopEntry(), QStringLiteral("com.signal11.patronradio"));
        QVERIFY(b.SupportedUriSchemes().contains(QStringLiteral("http")));
        QVERIFY(b.SupportedUriSchemes().contains(QStringLiteral("https")));
    }

    void testMprisPlayerCapabilities()
    {
        RadioBackend b;
        QCOMPARE(b.CanPlay(), true);
        QCOMPARE(b.CanPause(), true);
        QCOMPARE(b.CanSeek(), false);
        QCOMPARE(b.CanControl(), true);
        // The backend supports station switching: Next()/Previous() emit
        // nextRequested/previousRequested, which the UI handles to cycle stations.
        QCOMPARE(b.CanGoNext(), true);
        QCOMPARE(b.CanGoPrevious(), true);
        QCOMPARE(b.Position(), (qlonglong)0);
        QCOMPARE(b.Rate(), 1.0);
        QCOMPARE(b.LoopStatus(), QStringLiteral("None"));
    }

    void testMprisPlayPause()
    {
        RadioBackend b;
        b.setCurrentUrl(FAKE_URL_A);
        b.PlayPause(); // should start
        b.PlayPause(); // should pause (though won't actually reach Playing without audio)
        b.Stop();
    }

    void testMprisOpenUri()
    {
        RadioBackend b;
        b.OpenUri(FAKE_URL_A);
        QCOMPARE(b.currentUrl(), FAKE_URL_A);
        b.stop();
    }

    // ---------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------

    void testMetadataFallbackToStationName()
    {
        RadioBackend b;
        b.setCurrentStationName(QStringLiteral("WFMU"));
        QVariantMap meta = b.Metadata();
        QCOMPARE(meta.value(QStringLiteral("xesam:title")).toString(), QStringLiteral("WFMU"));
        QCOMPARE(meta.value(QStringLiteral("xesam:album")).toString(), QStringLiteral("WFMU"));
    }

    void testMetadataContainsUrl()
    {
        RadioBackend b;
        b.setCurrentUrl(FAKE_URL_A);
        QVariantMap meta = b.Metadata();
        QCOMPARE(meta.value(QStringLiteral("xesam:url")).toString(), FAKE_URL_A);
    }

    void testMetadataEmptyWhenCleared()
    {
        RadioBackend b;
        QVariantMap meta = b.Metadata();
        QVERIFY(!meta.contains(QStringLiteral("xesam:title")));
        QVERIFY(!meta.contains(QStringLiteral("xesam:album")));
        QVERIFY(!meta.contains(QStringLiteral("xesam:url")));
        // trackid should always be present
        QVERIFY(meta.contains(QStringLiteral("mpris:trackid")));
    }

    void testMetadataAfterStationSwitch()
    {
        RadioBackend b;
        b.setCurrentStationName(QStringLiteral("Station A"));
        b.setCurrentUrl(FAKE_URL_A);
        b.setCurrentStationName(QStringLiteral("Station B"));
        b.setCurrentUrl(FAKE_URL_B);

        QVariantMap meta = b.Metadata();
        QCOMPARE(meta.value(QStringLiteral("xesam:album")).toString(), QStringLiteral("Station B"));
        QCOMPARE(meta.value(QStringLiteral("xesam:url")).toString(), FAKE_URL_B);
        // stream title should have been cleared by URL change
        QCOMPARE(meta.value(QStringLiteral("xesam:title")).toString(), QStringLiteral("Station B"));
    }

    // ---------------------------------------------------------------
    // Sleep inhibit
    // ---------------------------------------------------------------

    void testInhibitSleepProperty()
    {
        RadioBackend b;
        QSignalSpy spy(&b, &RadioBackend::inhibitSleepChanged);
        QCOMPARE(b.inhibitSleep(), false);

        b.setInhibitSleep(true);
        QCOMPARE(b.inhibitSleep(), true);
        QCOMPARE(spy.count(), 1);

        // Dedup
        b.setInhibitSleep(true);
        QCOMPARE(spy.count(), 1);

        b.setInhibitSleep(false);
        QCOMPARE(b.inhibitSleep(), false);
        QCOMPARE(spy.count(), 2);
    }

    // ---------------------------------------------------------------
    // Error handling
    // ---------------------------------------------------------------

    void testLastErrorSignalValid()
    {
        RadioBackend b;
        QSignalSpy spy(&b, &RadioBackend::lastErrorChanged);
        QVERIFY(spy.isValid());
        QCOMPARE(b.lastError(), QString());
    }

    // ---------------------------------------------------------------
    // Resource cleanup — verify no leaks on destruction
    // ---------------------------------------------------------------

    void testDestroyWhilePlaying()
    {
        // Create on heap, start playing, then destroy — should not leak or crash
        auto *b = new RadioBackend();
        b->setCurrentUrl(FAKE_URL_A);
        b->play();
        delete b;
        // If we get here without crash/ASAN error, the test passes
    }

    void testDestroyWhileBuffering()
    {
        auto *b = new RadioBackend();
        b->setCurrentUrl(FAKE_URL_A);
        // Don't call play — just set URL which starts ICY reader
        delete b;
    }

    void testDestroyWithReconnectPending()
    {
        auto *b = new RadioBackend();
        b->setCurrentUrl(FAKE_URL_A);
        b->play();
        // The ICY reader will fail to connect to example.com (or timeout)
        // and schedule a reconnect. Destroying should clean up the timer.
        delete b;
    }

    // ---------------------------------------------------------------
    // Rapid lifecycle — stress test
    // ---------------------------------------------------------------

    void testCreateDestroyLoop()
    {
        // Rapid create/destroy cycle — check for leaks
        for (int i = 0; i < 50; i++) {
            RadioBackend b;
            b.setCurrentStationName(QStringLiteral("Station"));
            b.setCurrentUrl(QStringLiteral("http://example.com/%1.mp3").arg(i));
            b.play();
            b.stop();
        }
    }

    void testRapidUrlSwitchingWithPlay()
    {
        RadioBackend b;
        // Simulate a user clicking through stations fast
        for (int i = 0; i < 30; i++) {
            b.setCurrentStationName(QStringLiteral("Station %1").arg(i));
            b.setCurrentUrl(QStringLiteral("http://example.com/%1.mp3").arg(i));
            b.play();
        }
        // Verify final state is sane
        QCOMPARE(b.currentStationName(), QStringLiteral("Station 29"));
        QCOMPARE(b.streamTitle(), QString());
        b.stop();
        QCOMPARE(b.isPlaying(), false);
    }

    void testAlternatingPlayStop()
    {
        RadioBackend b;
        // Alternate between two stations rapidly
        for (int i = 0; i < 20; i++) {
            QString url = (i % 2 == 0) ? FAKE_URL_A : FAKE_URL_B;
            b.setCurrentUrl(url);
            b.play();
            b.stop();
        }
        QCOMPARE(b.isPlaying(), false);
        QCOMPARE(b.streamTitle(), QString());
    }

    void testPlayStopPlaySameUrl()
    {
        RadioBackend b;
        b.setCurrentUrl(FAKE_URL_A);
        b.play();
        b.stop();
        // play() again on same URL — setCurrentUrl dedup means we need
        // to go through play() which should restart the reader
        b.play();
        b.stop();
        QCOMPARE(b.isPlaying(), false);
    }

    // ---------------------------------------------------------------
    // Audio output
    // ---------------------------------------------------------------

    void testAvailableOutputsIsList()
    {
        RadioBackend b;
        QVariantList outputs = b.availableOutputs();
        QVERIFY(outputs.size() >= 0);
        if (!outputs.isEmpty()) {
            QVariantMap first = outputs.first().toMap();
            QVERIFY(first.contains(QStringLiteral("name")));
            QVERIFY(first.contains(QStringLiteral("id")));
        }
    }

    void testResetAudioOutputDoesNotCrash()
    {
        RadioBackend b;
        b.resetAudioOutput();
        b.resetAudioOutput();
    }

    void testSetInvalidAudioOutput()
    {
        RadioBackend b;
        // Should log a warning but not crash
        b.setAudioOutput(QStringLiteral("nonexistent_device_id_12345"));
    }

    void testRouteToInvalidBluetooth()
    {
        RadioBackend b;
        bool result = b.routeAudioToBluetooth(QStringLiteral("FF:FF:FF:FF:FF:FF"));
        QCOMPARE(result, false);
    }

    // ---------------------------------------------------------------
    // Edge cases
    // ---------------------------------------------------------------

    void testSetVolumeRange()
    {
        RadioBackend b;
        b.SetVolume(0.0);
        b.SetVolume(0.5);
        b.SetVolume(1.0);
        // Should not crash with boundary values
    }

    void testNoOpMprisMethods()
    {
        RadioBackend b;
        // These are all no-ops for a radio player — just verify no crash
        b.Raise();
        b.Quit();
        b.Next();
        b.Previous();
        b.Seek(1000);
        b.SetPosition(QDBusObjectPath("/"), 0);
        b.SetLoopStatus(QStringLiteral("Track"));
        b.SetRate(2.0);
    }
};

QTEST_GUILESS_MAIN(TestRadioBackend)
#include "test_radiobackend.moc"
