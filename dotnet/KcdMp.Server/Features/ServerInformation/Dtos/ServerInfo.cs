namespace KcdMp.Server.Features.ServerInformation.Dtos;

/// <summary>
/// Server info DTO.
/// </summary>
public record ServerInfo
{
	/// <summary>
	/// The map's name (Trosky or Kuttenberg)
	/// </summary>
	public string MapName { get; set; }
	
	/// <summary>
	/// The current player count.
	/// </summary>
	public int Players { get; set; }
	
	/// <summary>
	/// The max player count.
	/// </summary>
	public int MaxPlayers { get; set; }
	
	/// <summary>
	/// The server's tags.
	/// </summary>
	public string[] Tags { get; set; }
}