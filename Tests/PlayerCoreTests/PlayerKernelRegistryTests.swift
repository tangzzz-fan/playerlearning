import XCTest
@testable import PlayerCore

final class PlayerKernelRegistryTests: XCTestCase {
    func testEmptyRegistryExposesNothing() {
        let registry = PlayerKernelRegistry()

        XCTAssertTrue(registry.kernelTypes.isEmpty)
        XCTAssertNil(registry.firstKernelType)
        XCTAssertNil(registry.secondKernelType)
    }

    func testKernelTypesKeepDeclarationOrder() {
        let registry = PlayerKernelRegistry(kernelTypes: [
            KernelStub<StubTagB>.self,
            KernelStub<StubTagA>.self,
            KernelStub<StubTagC>.self
        ])

        XCTAssertEqual(registry.kernelTypes.count, 3)
        XCTAssertTrue(registry.kernelTypes[0] == KernelStub<StubTagB>.self)
        XCTAssertTrue(registry.kernelTypes[1] == KernelStub<StubTagA>.self)
        XCTAssertTrue(registry.kernelTypes[2] == KernelStub<StubTagC>.self)
    }

    func testSingleRegistrationFillsFirstOnly() {
        let registry = PlayerKernelRegistry(kernelTypes: [KernelStub<StubTagA>.self])

        XCTAssertTrue(registry.firstKernelType == KernelStub<StubTagA>.self)
        XCTAssertNil(registry.secondKernelType)
    }

    func testTwoRegistrationsFillFirstAndSecond() {
        let registry = PlayerKernelRegistry(kernelTypes: [
            KernelStub<StubTagA>.self,
            KernelStub<StubTagB>.self
        ])

        XCTAssertTrue(registry.firstKernelType == KernelStub<StubTagA>.self)
        XCTAssertTrue(registry.secondKernelType == KernelStub<StubTagB>.self)
    }

    func testSecondKernelIsSecondEntryNotLast() {
        let registry = PlayerKernelRegistry(kernelTypes: [
            KernelStub<StubTagA>.self,
            KernelStub<StubTagB>.self,
            KernelStub<StubTagC>.self
        ])

        XCTAssertTrue(registry.secondKernelType == KernelStub<StubTagB>.self)
    }

    func testRegisteredKernelTypeIsInstantiable() {
        let registry = PlayerKernelRegistry(kernelTypes: [KernelStub<StubTagA>.self])

        let kernel = registry.firstKernelType?.init()

        XCTAssertTrue(kernel is KernelStub<StubTagA>)
    }
}
