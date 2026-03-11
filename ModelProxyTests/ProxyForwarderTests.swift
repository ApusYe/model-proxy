import Testing
@testable import ModelProxy

struct ProxyForwarderTests {

    @Test func branchWaitBudgetStopsAfterConfiguredLimit() {
        var budget = ProxyForwarder.BranchWaitBudget(maxAttempts: 3)

        #expect(budget.recordWait() == true)
        #expect(budget.recordWait() == true)
        #expect(budget.recordWait() == true)
        #expect(budget.recordWait() == false)
        #expect(budget.attempts == 4)
    }
}
