using System;

namespace KCDMP_launcher.Services
{
    public class UiService
    {
        public event Action<string>? OnShowError;

        public void ShowError(string message)
        {
            OnShowError?.Invoke(message);
        }

        public void LogError(Exception? ex, string message)
        {
            Log.Error(ex, message);
            OnShowError?.Invoke(message);
        }
    }
}