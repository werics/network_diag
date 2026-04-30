#!/usr/bin/env swift
//
// Wi-Fi Info Helper for macOS
// Uses CoreWLAN framework to get unredacted Wi-Fi information
//

import CoreWLAN
import Foundation

func getWiFiInfo() -> [String: String] {
    var result: [String: String] = [:]

    guard let iface = CWWiFiClient.shared().interface() else {
        fputs("ERROR: No Wi-Fi interface found\n", stderr)
        return result
    }

    // SSID
    result["SSID"] = iface.ssid() ?? "N/A"

    // BSSID
    result["BSSID"] = iface.bssid() ?? "N/A"

    // RSSI
    result["RSSI"] = "\(iface.rssiValue())"

    // Noise
    result["Noise"] = "\(iface.noiseMeasurement())"

    // Channel
    if let channel = iface.wlanChannel() {
        let bandStr: String
        switch channel.channelBand {
        case .band5GHz: bandStr = "5GHz"
        case .band2GHz: bandStr = "2GHz"
        default:        bandStr = "Unknown"
        }

        let widthStr: String
        switch channel.channelWidth {
        case .width20MHz: widthStr = "20MHz"
        case .width40MHz: widthStr = "40MHz"
        case .width80MHz: widthStr = "80MHz"
        case .width160MHz: widthStr = "160MHz"
        default:          widthStr = "Unknown"
        }

        result["Channel"] = "\(channel.channelNumber) (\(bandStr), \(widthStr))"
    } else {
        result["Channel"] = "N/A"
    }

    // Tx Rate
    result["TxRate"] = "\(iface.transmitRate())"

    // PHY Mode
    let phyMode = iface.activePHYMode()
    switch phyMode {
    case .mode11a:  result["PHYMode"] = "802.11a"
    case .mode11b:  result["PHYMode"] = "802.11b"
    case .mode11g:  result["PHYMode"] = "802.11g"
    case .mode11n:  result["PHYMode"] = "802.11n"
    case .mode11ac: result["PHYMode"] = "802.11ac"
    case .mode11ax: result["PHYMode"] = "802.11ax"

    default:        result["PHYMode"] = "Unknown"
    }

    // Security
    let security = iface.security()
    switch security {
    case .none:              result["Security"] = "None"
    case .dynamicWEP:        result["Security"] = "Dynamic WEP"
    case .wpaPersonal:       result["Security"] = "WPA Personal"
    case .wpaEnterprise:     result["Security"] = "WPA Enterprise"
    case .wpa2Personal:      result["Security"] = "WPA2 Personal"
    case .wpa2Enterprise:    result["Security"] = "WPA2 Enterprise"
    case .wpa3Personal:      result["Security"] = "WPA3 Personal"
    case .wpa3Enterprise:    result["Security"] = "WPA3 Enterprise"
    case .wpa3Transition:    result["Security"] = "WPA3 Transition"
    case .personal:          result["Security"] = "WPA Personal"
    default:                 result["Security"] = "Unknown"
    }

    return result
}

// Print output in key:value format for easy shell parsing
let info = getWiFiInfo()
for (key, value) in info.sorted(by: { $0.key < $1.key }) {
    print("\(key):\(value)")
}
