using System;
using System.Net.Http;
using System.Net.Http.Json;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using KCDMP_launcher.Components.Shared;
using KCDMP_launcher.Models;
using Microsoft.AspNetCore.Components;

namespace KCDMP_launcher.Services
{
    public class NetService
    {
        private readonly UiService _uiService;

        private readonly HttpClient _httpClient;

        private string Prefix { get; } = "[NetService]";

        public NetService(UiService _uiService)
        {
            this._uiService = _uiService;
            this._httpClient = new HttpClient();
            this._httpClient.Timeout = TimeSpan.FromSeconds(5);
        }

        public int SendPingServer(string ip)
        {
            Log.Information($"{Prefix} Performing ping for IP: {ip}");
            int pingTime = -1;

            if (!ValidateIpAddr(ip, showError: false))
            {
                return -1;
            }

            try
            {
                using (Ping ping = new Ping())
                {
                    PingReply reply = ping.Send(ip, 1000);
                    if (reply.Status == IPStatus.Success)
                    {
                        pingTime = (int)reply.RoundtripTime;
                    }
                    else
                    {
                        //Ping is performed for every server on the list so I assume no errors should be shown to the user,
                        //just return -1 if ping fails for any reason
                        //serverList component will handle the display of ping times
                        //show "N/A" or similar for servers that couldn't be reached (ping < 0)

                        Log.Error(ip, $"Ping failed with status: {reply.Status}");
                    }
                }
            }
            catch (Exception ex)
            {
                //Same as above
                Log.Error(ex, "Error pinging server " + ip);

            }
            return pingTime;
        }

        public async Task<int> SendPingServerAsync(string ip)
        {
            Log.Information($"Performing ping async for IP: {ip}");
            int pingTime = -1;

            if (!ValidateIpAddr(ip, showError: false))
            {
                return -1;
            }

            try
            {
                using (Ping ping = new Ping())
                {
                    PingReply reply = await ping.SendPingAsync(ip, 1000);
                    if (reply.Status == IPStatus.Success)
                    {
                        return (int)reply.RoundtripTime;
                    }

                    return -1;
                }
            }
            catch (Exception ex)
            {
                Log.Error(ex, $"An error occurred while pinging {ip}");
            }
            return pingTime;
        }

        public async Task<List<ServerInfo>> GetServersFromMasterAsync(string masterUrl)
        {
            var resultList = new List<ServerInfo>();

            if (string.IsNullOrWhiteSpace(masterUrl) || !Uri.TryCreate(masterUrl, UriKind.Absolute, out _))
            {
                _uiService?.ShowError("Invalid Master Server URL in settings.");
                return resultList;
            }

            try
            {
                var dtoList = await _httpClient.GetFromJsonAsync<List<MasterServerEntry>>(masterUrl);

                if (dtoList != null)
                {
                    foreach (var entry in dtoList)
                    {
                        resultList.Add(new ServerInfo
                        {
                            Name = entry.Name,
                            Ip = entry.Ip,
                            Port = entry.Port,
                            MapName = "Loading...",
                            Ping = -1,
                            Players = 0,
                            MaxPlayers = 0
                        });
                    }
                }
            }
            catch (HttpRequestException ex)
            {
                _uiService?.LogError(ex, $"Could not connect to Master Server!");
            }
            catch (Exception ex)
            {
                _uiService?.LogError(ex, $"Error fetching server list!");
            }

            return resultList;
        }

        public async Task<DedicatedServerInfoData> GetDedicatedServerInfoAsync(string ip, int port)
        {
            var info = new DedicatedServerInfoData();

            try
            {
                // TODO: actual udp when we have server framework

                // Mock up for testing
                await Task.Delay(new Random().Next(50, 250));

                info.MapName = "trosecko";
                info.Players = new Random().Next(0, 32);
                info.MaxPlayers = 64;
            }
            catch
            {
                Log.Error($"Failed to get info for server {ip}:{port}");
            }

            return info;
        }

        public bool ValidateIpAddr(string ip, bool showError = true)
        {
            List<string> parts = ip.Split('.').ToList();
            if (parts.Count != 4)
            {
                if (showError)
                {
                    _uiService.ShowError("Invalid IP address format. An IP address must consist of 4 octets separated by dots.");
                }
                return false;
            }

            foreach (string part in parts)
            {
                
                if (!int.TryParse(part, out int num) || num < 0 || num > 255)
                {
                    if (showError)
                    {
                        _uiService.ShowError("Invalid IP address format. Each octet must be a number between 0 and 255.");
                    }
                    return false;
                }

                if (part == parts.Last() && num == 0)
                {
                    if (showError)
                    {
                        _uiService.ShowError("Invalid IP address format. The last octet cannot be 0.");
                    }
                    return false;
                }
            }
            return true;
        }

        public bool ValidatePort(int port, bool showError = true)
        {
            if (port < 1024 || port > 65535)
            {
                if (showError)
                {
                    _uiService.ShowError("Invalid port number. Port must be between 1024 and 65535.");
                }
                return false;
            }

            return true;
        }

        
    }
}