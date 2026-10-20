import Testing
@testable import SimulatorCore

struct BackgroundServicesTests {
    @Test func parsesDisabledOverrides() {
        let output = """

        \tdisabled services = {
        \t\t"com.apple.weatherd" => disabled
        \t\t"com.example.enabled" => enabled
        \t\t"com.apple.homed" => disabled
        \t}
        """
        #expect(Simctl.parseDisabledServices(output) == ["com.apple.weatherd", "com.apple.homed"])
    }

    @Test func groupCountsOnlyWhenEveryLabelIsDisabled() {
        var disabled = Set(ServiceGroup.home.labels)
        disabled.insert(ServiceGroup.siri.labels[0])
        #expect(ServiceGroup.fullyDisabled(in: disabled) == [.home])
    }

    @Test func labelsBelongToOneGroup() {
        let labels = ServiceGroup.allCases.flatMap(\.labels)
        #expect(Set(labels).count == labels.count)
        #expect(Set(labels).isDisjoint(with: ServiceGroup.retiredLabels))
    }
}
