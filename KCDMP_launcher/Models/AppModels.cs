using System.Text.Json.Serialization;
using System.Threading.Tasks;
using KCDMP_launcher.Services;

namespace KCDMP_launcher.Models
{
    public class ServerInfo
    {
        public string? Token { get; set; } = null; // Unique identifier for the server, will be used for caching mods profiles.
        public string Name { get; set; } = "";
        public string Ip { get; set; } = "";
        public int Port { get; set; }

        public string MapName { get; set; } = "";
        public int Players { get; set; } = 0;
        public int MaxPlayers { get; set; } = 0;
        public int Ping { get; set; } = -1;

        public bool IsOnline { get; set; } = false;
    }

    // DTO
    // [ {"name": "abc", "ip": "127.0.0.1", "port": 1234} ] or something
    public class MasterServerEntry
    {
        [JsonPropertyName("name")]
        public string Name { get; set; } = "";

        [JsonPropertyName("ip")]
        public string Ip { get; set; } = "";

        [JsonPropertyName("port")]
        public int Port { get; set; }

    }

    public class DedicatedServerInfoData
    {
        public string MapName { get; set; } = "Unknown";
        public int Players { get; set; } = 0;
        public int MaxPlayers { get; set; } = 0;
    }

    public class AppSettings
    {
        public string GamePath { get; set; } = "";
        public string DllPath { get; set; } = "KCDMP.dll";

        // This is the URL of the master server API endpoint that the launcher will query to get the list of available servers.
        // Configurable by user, but default points to localhost for testing purposes.
        // !IMPORTANT change it in release
        public string MasterServerUrl { get; set; } = "http://localhost:5000/api/servers";
        public string Language { get; set; } = "en";
    }
}