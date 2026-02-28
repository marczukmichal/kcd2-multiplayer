namespace KcdMp.Client.Lua;

public class LuaSetGhostName : LuaCommand<(string ghostId, string safeName)>
{
    protected override string LuaName => "KCD2MP_SetGhostName";
}

public class LuaUpdateGhost : LuaCommand<(string ghostId, float gx, float gy, float gz, float rot, bool isRiding)>
{
    protected override string LuaName => "KCD2MP_UpdateGhost";
}