using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace KCDMP_launcher.Components.Shared
{
    public class StyleProfile : BaseProfile
    {
        public string Id { get; set; } = Guid.NewGuid().ToString();

        public string ProfileName { get; set; } = string.Empty;
        public string FontFamily { get; set; } = "Libre Baskerville";
        public string SpecialFontFamily { get; set; } = "Cinzel";
        public int FontSize { get; set; } = 14;
        public int FontWeight { get; set; } = 400;
        public string FontColor { get; set; } = "#1e1e1e";

        public void SaveProfileToFile()
        {
            base.SaveProfileToFile(Globals.StylesProfilesDirectoryPath, $"{ProfileName}_{Id}");
        }
    }
}
