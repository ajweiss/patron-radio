#ifndef RADIOBACKENDPLUGIN_H
#define RADIOBACKENDPLUGIN_H

#include <QQmlExtensionPlugin>
#include <QQmlEngine>
#include <qqml.h>
#include "radiobackend.h"

// This class acts as the entry point for our QML module
class RadioBackendPlugin : public QQmlExtensionPlugin
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid FILE "com.signal11.patronradio.json")

public:
    void registerTypes(const char *uri) override
    {
        // Register our singleton C++ class under the QML module
        qmlRegisterSingletonType<RadioBackend>(uri, 1, 0, "RadioBackend",
            [](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject * {
                Q_UNUSED(scriptEngine);
                return new RadioBackend(engine);
            });
    }
};

#endif // RADIOBACKENDPLUGIN_H
