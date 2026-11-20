import CoreAudio
import Testing
@testable import WhisperShortcut_AppStore

/// The transport filter is the only catalog decision that does not need a live device.
/// `defaultInputDevice()` reads CoreAudio and is covered by using the pill, not here.
@Suite("Audio input device catalog")
struct AudioInputDeviceCatalogTests {

  @Test("Virtual and aggregate transports are not microphones")
  func rejectsLoopbackTransports() {
    #expect(!AudioInputDeviceCatalog.isPhysicalTransport(kAudioDeviceTransportTypeVirtual))
    #expect(!AudioInputDeviceCatalog.isPhysicalTransport(kAudioDeviceTransportTypeAggregate))
    #expect(!AudioInputDeviceCatalog.isPhysicalTransport(kAudioDeviceTransportTypeAutoAggregate))
  }

  @Test("Built-in, USB, Bluetooth and an unknown transport stay microphones")
  func acceptsPhysicalTransports() {
    #expect(AudioInputDeviceCatalog.isPhysicalTransport(kAudioDeviceTransportTypeBuiltIn))
    #expect(AudioInputDeviceCatalog.isPhysicalTransport(kAudioDeviceTransportTypeUSB))
    #expect(AudioInputDeviceCatalog.isPhysicalTransport(kAudioDeviceTransportTypeBluetooth))
    #expect(AudioInputDeviceCatalog.isPhysicalTransport(kAudioDeviceTransportTypeBluetoothLE))
    #expect(AudioInputDeviceCatalog.isPhysicalTransport(kAudioDeviceTransportTypeThunderbolt))
    #expect(AudioInputDeviceCatalog.isPhysicalTransport(kAudioDeviceTransportTypePCI))
    #expect(AudioInputDeviceCatalog.isPhysicalTransport(0))
  }
}
