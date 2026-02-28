using System.Globalization;
using System.Text;

namespace KcdMp.Client.Lua;

public abstract class LuaCommand<TArgs> where TArgs : struct
{
    
    protected abstract string LuaName { get; }

    public string GetExecution(TArgs args)
    {
        var values = typeof(TArgs).GetFields();
        var sb = new StringBuilder($"{LuaName}");
        
        for (int i = 0; i < values.Length; i++)
        {
            if (i > 0)
                sb.Append(", ");

            var value = values[i].GetValue(args);
            
            if (value is IFormattable formattable)
            {
                sb.Append(formattable.ToString(null, CultureInfo.InvariantCulture));
            }
            else
            {
                sb.Append(value);
            }
        }

        sb.Append(')');
        return sb.ToString();
    }
}