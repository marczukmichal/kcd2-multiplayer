using KCDMP_launcher.Components.Shared;
using Microsoft.AspNetCore.Components;

namespace KCDMP_launcher.Components
{
    public class ModalBase : Base
    {
        [Parameter] public bool IsVisible { get; set; }
        [Parameter] public EventCallback<bool> IsVisibleChanged { get; set; }
        [Parameter] public EventCallback OnClose { get; set; }

        protected bool isClosing { get; set; }

        protected async Task CloseModalAsync()
        {
            if (isClosing) return;

            isClosing = true;
            StateHasChanged();

            await Task.Delay(200);

            isClosing = false;
            IsVisible = false;

            await IsVisibleChanged.InvokeAsync(false);
            await OnClose.InvokeAsync();

            StateHasChanged();
        }
    }
}