using KcdMp.Server.Features.ClientHandling;
using KcdMp.Server.Features.ServerInformation.Dtos;
using Microsoft.AspNetCore.Mvc;

namespace KcdMp.Server.Features.ServerInformation.Controllers;

/// <summary>
/// Controller for endpoints that provide server information.
///
/// Called by the master server.
/// </summary>
[ApiController]
[Route("api/[controller]")]
public class InformationController : ControllerBase
{
	private readonly ServerInfo _serverInfo;
	private readonly ClientHandler _clientHandler;
	
	public InformationController(IConfiguration configuration, ClientHandler clientHandler)
	{
		// TODO: Make this actually configurable
		var infoSection = configuration.GetSection("ServerInfo");
		infoSection.Bind(_serverInfo = new ServerInfo());
		
		_clientHandler = clientHandler;
	}
	
	/// <summary>
	/// Returns the server's main information.
	/// </summary>
	/// <returns></returns>
	[HttpGet]
	[ProducesResponseType(StatusCodes.Status200OK)]
	public IActionResult GetInfo()
	{
		_serverInfo.Players = _clientHandler.ClientCount;
		
		return Ok(_serverInfo);
	}
}