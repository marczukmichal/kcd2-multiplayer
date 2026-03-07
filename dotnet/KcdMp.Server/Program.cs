using KcdMp.Server.Features.ClientHandling;
using KcdMp.Server.Features.Tcp;
using Serilog;

namespace KcdMp.Server;

class Program
{
	/// <summary>
	/// The server's entry point.
	/// </summary>
	static async Task Main(string[] args)
	{
		var builder = WebApplication.CreateBuilder(args);
		
		// Logging config
		builder.Services.AddSerilog(options =>
		{
			options.ReadFrom.Configuration(builder.Configuration);
		});

		// Add controllers for HTTP API's
		builder.Services.AddControllers();
		
		// Add TCP Socket as background service
		builder.Services.AddHostedService<TcpSocketService>();
		
		builder.Services.AddSingleton<ClientHandler>();
		builder.Services.AddSingleton<TcpBroadcastService>();

		await using var app = builder.Build();
		
		// Map controller routs
		app.MapControllers();
		
		await app.RunAsync();
	}
}