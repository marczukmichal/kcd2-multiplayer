using System.Net;
using System.Net.Sockets;
using KcdMp.Server.Features.ClientHandling;
using ILogger = Serilog.ILogger;

namespace KcdMp.Server.Features.Tcp;

/// <summary>
/// Background service that exposes a TCP socket and handles incoming traffic.
/// </summary>
public class TcpSocketService : BackgroundService
{
	private readonly SemaphoreSlim _semaphore = new SemaphoreSlim(1, 1);
	
	private readonly ILogger _logger;
	private readonly int _port;
	private readonly ClientHandler _clientHandler;
	private readonly TcpBroadcastService _broadcastService;
	
	public TcpSocketService(ILogger logger, IConfiguration configuration, 
		ClientHandler clientHandler, TcpBroadcastService broadcastService)
	{
		_logger = logger;
		
		var configSection = configuration.GetSection("Tcp");
		_port = int.Parse(configSection["Port"] ?? "8080");
		
		_clientHandler = clientHandler;
		_broadcastService = broadcastService;
	}
	
	/// <summary>
	/// The actual logic executed by the service on startup.
	///
	/// Handles the TCP socket.
	/// </summary>
	/// <param name="cancellationToken"></param>
	protected override async Task ExecuteAsync(CancellationToken cancellationToken)
	{
		var listener = new TcpListener(IPAddress.Any, _port);
		listener.Start();
		_logger.Debug($"Listening on port {_port}...");
		_logger.Debug("Waiting for clients to connect.");

		try
		{
			while (true)
			{
				cancellationToken.ThrowIfCancellationRequested();
				
				var tcpListener = await listener.AcceptTcpClientAsync(cancellationToken);
				var client = new ClientSession(_logger, tcpListener, _broadcastService);

				await _semaphore.WaitAsync(cancellationToken);
				try
				{
					_clientHandler.AddClient(client);
				}
				finally
				{
					_semaphore.Release();
				}
				
				_ = client.RunAsync().ContinueWith(async _ =>
				{
					await _semaphore.WaitAsync(cancellationToken);
					try
					{
						_clientHandler.RemoveClient(client);
					}
					finally
					{
						_semaphore.Release();
					}
					
					_logger.Debug("[-] {ClientName} disconnected. Clients: {ClientHandlerClientCount}", 
						client.Name ?? $"id={client.Id}", _clientHandler.ClientCount);
					if (client.IsReady)
						_broadcastService.BroadcastDisconnect(client);
				}, cancellationToken);
			}
		}
		catch (TaskCanceledException e)
		{
			_logger.Information(e, "TCP Socket closed.");
		}
	}
}