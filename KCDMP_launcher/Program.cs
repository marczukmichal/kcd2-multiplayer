// See https://aka.ms/new-console-template for more information
using Photino.Blazor;
using Microsoft.Extensions.DependencyInjection;
using KCDMP_launcher;
using System.IO;
using System;
using KCDMP_launcher.Services;
using Microsoft.Extensions.Logging;
using Serilog;
using KCDMP_launcher.Components.Shared;

class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        Log.Logger = new LoggerConfiguration()
            .MinimumLevel.Debug()
            .WriteTo.File(Path.Combine(Globals.AppFolder, "app.log"),
                rollingInterval: RollingInterval.Day,
                retainedFileCountLimit: 10)
            .CreateLogger();

        try
        {
            Log.Information("=== Start KCD2 MP Launcher ===");

            var appBuilder = PhotinoBlazorAppBuilder.CreateDefault(args);

            var baseDir = AppDomain.CurrentDomain.BaseDirectory;
            var wwwrootPath = Path.Combine(baseDir, "wwwroot");

            if (Directory.Exists(wwwrootPath))
            {
                appBuilder.Services.AddSingleton<Microsoft.Extensions.FileProviders.IFileProvider>(
                    new Microsoft.Extensions.FileProviders.PhysicalFileProvider(wwwrootPath));
            }

            appBuilder.Services.AddLogging(loggingBuilder =>
            {
                loggingBuilder.ClearProviders();
                loggingBuilder.AddSerilog(dispose: true);
            });

            appBuilder.Services.AddSingleton<KCDMP_launcher.Services.UiService>();
            appBuilder.Services.AddSingleton<KCDMP_launcher.Services.NetService>();
            appBuilder.RootComponents.Add<App>("#app");

            var app = appBuilder.Build();

            app.MainWindow
                .SetTitle("KCD2 MP Launcher")
                .SetSize(1600, 900)
                .SetMaximized(true)
                .SetResizable(true)
                .SetContextMenuEnabled(false)
                .Center();

            AppDomain.CurrentDomain.UnhandledException += (sender, error) =>
            {
                var ex = error.ExceptionObject as Exception;
                Log.Fatal(ex, "Unexpected expection!");
                app.MainWindow.ShowMessage("Fatal Error", error.ExceptionObject.ToString());
            };

            app.Run();
        }
        catch (Exception ex)
        {
            Log.Fatal(ex, "App encountered an error while launching!");
        }
        finally
        {
            Log.CloseAndFlush();
        }
    }
}