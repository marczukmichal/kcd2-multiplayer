using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.NetworkInformation;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms.Design;
using KCDMP_launcher.Services;
using Microsoft.AspNetCore.Components;

namespace KCDMP_launcher.Components.Shared
{
    public class Base : ComponentBase
    {
        [Inject]
        protected UiService UiService { get; set; } = default!;

        [Inject]
        protected NetService NetService { get; set; } = default!;

    }
}
