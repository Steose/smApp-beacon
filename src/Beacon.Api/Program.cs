var builder = WebApplication.CreateBuilder(args);
builder.Services.ConfigureHttpJsonOptions(options =>
    options.SerializerOptions.WriteIndented = true);
var app = builder.Build();

app.MapGet("/", () => new
{
    app = "Beacon",
    status = "ok",
    version = "4"
});

// Health check. Used by App Service (week 35), by health-check.sh (week 36)
// and by the container (week 38). Do not remove.
app.MapGet("/health", () => Results.Ok(new
{
    status = "healthy",
    version = "1.0.0"
}));

app.MapGet("/info", () => new
{
    app = "Beacon",
    machine = Environment.MachineName,
    environment = Environment.GetEnvironmentVariable("BEACON_ENVIRONMENT") ?? "unset",
    message = Environment.GetEnvironmentVariable("BEACON_MESSAGE") ?? "unset",
    apiKeySet = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("BEACON_API_KEY"))
});

app.Run();

// Makes Program visible to the test project.
public partial class Program { }