// A monthly budget for the whole subscription, with an email at 50% and 100% of
// what has actually been spent. It costs nothing and changes nothing: it only warns.
targetScope = 'subscription'

@description('Where the alerts go.')
param email string

@description('The monthly amount, in your billing currency (SEK for most of you).')
param amount int = 50

@description('The first day of the current month. Leave it as it is.')
param startDate string = utcNow('yyyy-MM-01')

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: 'budget-clo25'
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      actual_GreaterThan_50_Percent: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: [
          email
        ]
      }
      actual_GreaterThan_100_Percent: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: [
          email
        ]
      }
    }
  }
}
