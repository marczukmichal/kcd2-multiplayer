namespace KcdMp.Server.Features.ClientHandling;

/// <summary>
/// Helper class for client handling.
/// </summary>
public class ClientHandler
{
	private readonly IList<ClientSession> _clients = [];
	
	/// <summary>
	/// Add a client.
	///
	/// Called when a client connects.
	/// </summary>
	/// <param name="client"></param>
	public void AddClient(ClientSession client) => 
		_clients.Add(client);
	
	/// <summary>
	/// Remove a client.
	///
	/// Called when a client disconnects.
	/// </summary>
	/// <param name="client"></param>
	public void RemoveClient(ClientSession client) => 
		_clients.Remove(client);
	
	/// <summary>
	/// Gets a copy of the client list to prevent outside manipulation.
	/// </summary>
	/// <returns></returns>
	public ClientSession[] GetClients() =>
		_clients.ToArray();

	/// <summary>
	/// Returns the current player count.
	/// </summary>
	public int ClientCount =>
		_clients.Count;
}