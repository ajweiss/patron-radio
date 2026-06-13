import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: "Behavior"
        icon: "preferences-system"
        source: "configBehavior.qml"
    }
    ConfigCategory {
        name: "Loudness"
        icon: "audio-volume-high"
        source: "configLoudness.qml"
    }
    ConfigCategory {
        name: "Appearance"
        icon: "preferences-desktop-theme"
        source: "configAppearance.qml"
    }
    ConfigCategory {
        name: "Stations"
        icon: "network-wireless"
        source: "configGeneral.qml"
    }
}
