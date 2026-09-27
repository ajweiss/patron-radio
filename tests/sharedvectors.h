#ifndef SHAREDVECTORS_H
#define SHAREDVECTORS_H

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QString>
#include <QtTest>

// Loads the "cases" array of a shared test-vector file from tests/data/.
// The same files drive the macOS app's tests (macos/Tests/), so both
// implementations are held to one written-down set of rules.
// Returns an empty array if the file is missing or malformed; callers
// QVERIFY that it isn't, so a broken file fails loudly.
inline QJsonArray loadSharedCases(const QString &fileName)
{
    const QString path = QFINDTESTDATA(QStringLiteral("data/") + fileName);
    QFile file(path);
    if (path.isEmpty() || !file.open(QIODevice::ReadOnly))
        return {};
    return QJsonDocument::fromJson(file.readAll()).object().value(QLatin1String("cases")).toArray();
}

#endif // SHAREDVECTORS_H
