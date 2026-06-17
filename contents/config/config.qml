import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("Behavior")
        icon: "preferences-system"
        source: "configBehavior.qml"
    }
    ConfigCategory {
        name: i18n("Loudness")
        icon: "audio-volume-high"
        source: "configLoudness.qml"
    }
    ConfigCategory {
        name: i18n("Appearance")
        icon: "preferences-desktop-theme"
        source: "configAppearance.qml"
    }
    ConfigCategory {
        name: i18n("Stations")
        icon: "network-wireless"
        source: "configGeneral.qml"
    }
}
