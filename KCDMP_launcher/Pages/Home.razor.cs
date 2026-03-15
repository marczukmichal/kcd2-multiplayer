using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using KCDMP_launcher.Components;
using KCDMP_launcher.Models;
using KCDMP_launcher.Services;
using Microsoft.AspNetCore.Components;
using Microsoft.JSInterop;
using Serilog;


// TO DO
// SPLIT THIS MF INTO SEVERAL COMPONENTS, THIS FILE IS GETTING OUT OF HAND

namespace KCDMP_launcher.Pages
{
    public partial class Home
    {

        [Inject] public required IJSRuntime JSRuntime { get; set; }
        [Inject] public required UiService UiService { get; set; }

        [Inject] public required NetService NetService { get; set; }

        #region Constants
        private const string FavoritesFileName = "favorites.json";
        private const string SettingsFileName = "settings.json";
        private ServerList? serverListComponent;
        #endregion

        #region State
        private bool isLoading = false;
        private string errorMessage = "";



        // Modals
        private bool showExitConfirm = false;
        private bool showSettings = false;

        private DotNetObjectReference<Home>? objRef;
        private AppSettings settings = new AppSettings();
        private ServerInfo? serverToEdit = null;
        #endregion

        #region Filter State
        private bool isFilterOpen = false;
        private string filterName = "";
        private string filterMap = "";
        private int? filterMinPlayers;
        private int? filterMaxPlayers;
        private int? filterMinPing;
        private int? filterMaxPing;
        private bool filterShowFavorites = false;
        private bool filterHideUnreachable = false;
        #endregion

        #region Data & Logic
        private HashSet<string> favoriteIps = new HashSet<string>();
        private string currentSortColumn = "Players";
        private bool isAscending = false;

        // Dummy Data
        private List<ServerInfo> servers = new List<ServerInfo>();
    //    private List<ServerInfo> servers = new List<ServerInfo>
    //{
    //    new ServerInfo { Name = "Official PL Server #1", Ip = "127.0.0.1", Port = 27015, MapName = "skalitz_survival", Players = 12, MaxPlayers = 64, Ping = 25 },
    //    new ServerInfo { Name = "Roleplay Tavern", Ip = "192.168.1.5", Port = 7777, MapName = "rataje_city", Players = 60, MaxPlayers = 64, Ping = 42 },
    //    new ServerInfo { Name = "High Ping Test", Ip = "10.0.0.2", Port = 28000, MapName = "debug_map", Players = 1, MaxPlayers = 10, Ping = 150 },
    //    new ServerInfo { Name = "Laggy Server", Ip = "10.0.0.2", Port = 28000, MapName = "forest", Players = 5, MaxPlayers = 10, Ping = 80 },
    //    new ServerInfo { Name = "Polish Hussars", Ip = "10.0.0.5", Port = 28000, MapName = "skalitz_survival", Players = 32, MaxPlayers = 64, Ping = 30 },
    //};
        private const string CustomServersFileName = "custom_servers.json";
        private bool showAddServer = false;
        private List<ServerInfo> customServers = new List<ServerInfo>();

        public void DisplayError()
        {
            UiService.ShowError("This is a test error message!");
        }

        private IEnumerable<ServerInfo> filteredAndSortedServers
        {
            get
            {
                var allServers = servers.Concat(customServers).AsEnumerable();
                var query = allServers;

                if (!string.IsNullOrWhiteSpace(filterName))
                    query = query.Where(s => s.Name != null && s.Name.Contains(filterName, StringComparison.OrdinalIgnoreCase));

                if (!string.IsNullOrWhiteSpace(filterMap) && filterMap != "All Maps")
                    query = query.Where(s => s.MapName == filterMap);

                if (filterMinPlayers.HasValue) query = query.Where(s => s.Players >= filterMinPlayers.Value);
                if (filterMaxPlayers.HasValue) query = query.Where(s => s.Players <= filterMaxPlayers.Value);

                if (filterMinPing.HasValue) query = query.Where(s => s.Ping >= filterMinPing.Value);
                if (filterMaxPing.HasValue) query = query.Where(s => s.Ping <= filterMaxPing.Value);

                if (filterHideUnreachable)
                {
                    query = query.Where(s => s.Ping >= 0);
                }

                if (filterShowFavorites)
                    query = query.Where(s => favoriteIps.Contains(s.Ip));

                return currentSortColumn switch
                {
                    "Name" => isAscending ? query.OrderBy(s => s.Name) : query.OrderByDescending(s => s.Name),
                    "Map" => isAscending ? query.OrderBy(s => s.MapName) : query.OrderByDescending(s => s.MapName),
                    "Players" => isAscending ? query.OrderBy(s => s.Players) : query.OrderByDescending(s => s.Players),
                    "Ping" => isAscending ? query.OrderBy(s => s.Ping) : query.OrderByDescending(s => s.Ping),
                    _ => query
                };
            }
        }
        private List<string> availableMaps => servers.Select(s => s.MapName).Distinct().ToList();

        private void ResetFilters()
        {
            filterName = "";
            filterMap = "";
            filterMinPlayers = null;
            filterMaxPlayers = null;
            filterMinPing = null;
            filterMaxPing = null;
            filterShowFavorites = false;
            filterHideUnreachable = true;
            StateHasChanged();
        }
        #endregion

        #region Lifecycle & Methods
        protected override async Task OnInitializedAsync()
        {
            LoadFavorites();
            LoadSettings();
            LoadCustomServers();
            await RefreshApp();
        }

        //CUSTOM SERVERS LOGIC 
        private void LoadCustomServers()
        {
            try
            {
                if (File.Exists(CustomServersFileName))
                {
                    var json = File.ReadAllText(CustomServersFileName);
                    var loaded = JsonSerializer.Deserialize<List<ServerInfo>>(json);
                    if (loaded != null) customServers = loaded;
                }
            }
            catch { }
        }

        private void AddCustomServer(ServerInfo newServer)
        {
            if (!customServers.Any(s => s.Ip == newServer.Ip && s.Port == newServer.Port))
            {
                customServers.Add(newServer);
                SaveCustomServers();
            }
            showAddServer = false;
            StateHasChanged();
        }
        private void OpenAddModal()
        {
            serverToEdit = null;
            showAddServer = true;
            StateHasChanged();
        }

        public void OpenEditModal(ServerInfo server)
        {
            serverToEdit = server;
            showAddServer = true;
            StateHasChanged();
        }

        private void HandleServerUpdate(ServerInfo updatedServer)
        {
            SaveCustomServers();
            StateHasChanged();
        }


        private void RemoveCustomServer(ServerInfo server)
        {
            var customToRemove = customServers.FirstOrDefault(s => s.Ip == server.Ip && s.Port == server.Port);

            if (customToRemove != null)
            {
                customServers.Remove(customToRemove);

                SaveCustomServers();
                serverListComponent?.ClearSelection();
                StateHasChanged();
            }
        }

        private void SaveCustomServers()
        {
            try
            {
                var json = JsonSerializer.Serialize(customServers);
                File.WriteAllText(CustomServersFileName, json);
            }
            catch { }
        }

        protected override async Task OnAfterRenderAsync(bool firstRender)
        {
            if (firstRender)
            {
                objRef = DotNetObjectReference.Create(this);
                await JSRuntime.InvokeVoidAsync("registerGlobalKeys", objRef);

                await JSRuntime.InvokeVoidAsync("eval", @"
                document.addEventListener('keydown', (e) => {
                    if(e.key === 'F10') {
                        e.preventDefault();
                        DotNet.invokeMethodAsync('KCDMP_launcher', 'ToggleSettingsStatic');
                    }
                })
            ");
            }
        }

        public void Dispose() => objRef?.Dispose();

        // JS Invokables
        [JSInvokable("ToggleSettingsStatic")] public static void ToggleSettingsStatic() { }

        [JSInvokable]
        public void ToggleFiltersJS()
        {
            isFilterOpen = !isFilterOpen;
            StateHasChanged();
        }

        [JSInvokable]
        public void ToggleSettingsJS()
        {
            showSettings = !showSettings;
            StateHasChanged();
        }

        [JSInvokable]
        public void ExitApp()
        {
            if (showSettings) { showSettings = false; StateHasChanged(); return; }
            if (isFilterOpen) { isFilterOpen = false; StateHasChanged(); return; }
            showExitConfirm = true;
            StateHasChanged();
        }

        [JSInvokable]
        public async Task RefreshApp()
        {
            if (isLoading) return;
            isLoading = true;
            StateHasChanged();

            var fetchedServers = await NetService.GetServersFromMasterAsync(settings.MasterServerUrl);
            servers = fetchedServers;
            StateHasChanged();

            var tasks = servers.Select(async server =>
            {
                server.Ping = await NetService.SendPingServerAsync(server.Ip);

                var details = await NetService.GetDedicatedServerInfoAsync(server.Ip, server.Port);

                if (details != null)
                {
                    server.MapName = details.MapName;
                    server.Players = details.Players;
                    server.MaxPlayers = details.MaxPlayers;
                    server.IsOnline = true;
                }
                await InvokeAsync(StateHasChanged);
            });

            await Task.WhenAll(tasks);

            isLoading = false;
            StateHasChanged();
        }


        // Actions
        private void SortTable(string columnName) 
        { 
            if (currentSortColumn == columnName) 
            { 
                isAscending = !isAscending; 
            }
            else 
            { 
                currentSortColumn = columnName; isAscending = true; 
            } 
        }

        private void ToggleFavorite(ServerInfo server)
        {
            if (favoriteIps.Contains(server.Ip)) favoriteIps.Remove(server.Ip);
            else favoriteIps.Add(server.Ip);
            SaveFavorites();
        }

        private async Task LaunchGame(ServerInfo server)
        {
            if (string.IsNullOrEmpty(settings.GamePath) || !File.Exists(settings.GamePath))
            {
                UiService.ShowError("Game Executable not found! Please check Settings.");
                return;
            }

            if (!IsServerReachable(server))
            {
                UiService.ShowError("Server is unreachable. Cannot launch.");
                return;
            }

            if (!ConfirmLevelExists(server.MapName))
            {
                return;
            }

            string dllFullPath = settings.DllPath;

            if (!Path.IsPathRooted(dllFullPath))
            {
                string gameDir = Path.GetDirectoryName(settings.GamePath) ?? "";
                dllFullPath = Path.Combine(gameDir, dllFullPath);
            }

            dllFullPath = Path.GetFullPath(dllFullPath);

            if (!File.Exists(dllFullPath))
            {
                UiService.ShowError($"Multiplayer DLL not found at: {dllFullPath}");
                return;
            }

            string injectorPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "KCDMP_LauncherInjector.exe");

            if (!File.Exists(injectorPath))
            {
                UiService.ShowError($"Injector executable not found at: {injectorPath}");
                return;
            }

            try
            {
                string gameArgs = $"+map {server.MapName} --kcdmp-ip {server.Ip} --kcdmp-port {server.Port}";

                var gameStartInfo = new ProcessStartInfo
                {
                    FileName = settings.GamePath,
                    Arguments = gameArgs,
                    UseShellExecute = false,
                    WorkingDirectory = Path.GetDirectoryName(settings.GamePath)
                };

                UiService.ShowError($"Launching: {gameArgs}");
                var gameProcess = Process.Start(gameStartInfo);

                if (gameProcess != null)
                {
                    await Task.Delay(3000);

                    if (gameProcess.HasExited)
                    {
                        UiService.ShowError("Game process exited unexpectedly before injection.");
                        return;
                    }

                    var injectorStartInfo = new ProcessStartInfo
                    {
                        FileName = injectorPath,
                        Arguments = $"--pid {gameProcess.Id} --dll \"{dllFullPath}\"",
                        UseShellExecute = false,
                        CreateNoWindow = true
                    };

                    Process.Start(injectorStartInfo);
                }
            }
            catch (Exception ex)
            {
                errorMessage = ex.Message;
                UiService.ShowError($"Critical Launch Error: {ex.Message}");
            }
        }

        private bool IsServerReachable(ServerInfo server)
        {
            if (server.Ping < 0)
            {
                return false;
            }
            return true;
        }

        private bool ConfirmLevelExists(string mapName)
        {
            if (string.IsNullOrEmpty(settings.GamePath) || !File.Exists(settings.GamePath))
            {
                UiService.ShowError("Game executable not found!");
                return false;
            }

            try
            {
                string exeDir = Path.GetDirectoryName(settings.GamePath) ?? "";
                string gameDir = Directory.GetParent(exeDir)?.Parent?.FullName ?? "";
                string levelsDir = Path.Combine(gameDir, "Data", "Levels");
                
                if (!Directory.Exists(levelsDir))
                {
                    UiService.ShowError($"Levels directory not found: {levelsDir}");
                    return false;
                }

                string levelFile = Path.Combine(levelsDir, mapName);

                if (!Directory.Exists(levelFile))
                {
                    UiService.ShowError($"Level not found: {levelFile}");
                    return false;
                }
            }
            catch (Exception ex)
            {
                UiService.ShowError("Error occured while searching for level");

            }
            return true;
        }


        private void ConfirmExit() => Environment.Exit(0);

        // Persistence
        private void LoadFavorites() { try { if (File.Exists(FavoritesFileName)) favoriteIps = JsonSerializer.Deserialize<HashSet<string>>(File.ReadAllText(FavoritesFileName)) ?? new(); } catch { } }
        private void SaveFavorites() { try { File.WriteAllText(FavoritesFileName, JsonSerializer.Serialize(favoriteIps)); } catch { } }

        private void LoadSettings() { try { if (File.Exists(SettingsFileName)) settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsFileName)) ?? new(); } catch { } }
        private void SaveSettings()
        {
            try
            {
                File.WriteAllText(SettingsFileName, JsonSerializer.Serialize(settings));
                showSettings = false;
            }
            catch (Exception ex) { errorMessage = ex.Message; }
        }


        #endregion
    }
}

