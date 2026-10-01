using './security.bicep'

param vaultName = 'kv-clo25-steven'
param appName = 'app-clo25-steven'
param deployerObjectId = '5141e805-3a9e-4ad7-8a36-06da9eedaf6b'

// The secret is read from an environment variable at deploy time.
// The deploy stops with BCP427 if the variable has not been set.
param secretValue = readEnvironmentVariable('SECRET_VALUE')
