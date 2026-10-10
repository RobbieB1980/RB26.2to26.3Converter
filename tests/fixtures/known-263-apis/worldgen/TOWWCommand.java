import net.minecraft.commands.CommandSource;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.network.chat.Component;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.permissions.LevelBasedPermissionSet;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.phys.Vec2;
import net.minecraft.world.phys.Vec3;

class TOWWCommand {
  CommandSourceStack source(ServerLevel level, double x, double y, double z) {
    return new CommandSourceStack(CommandSource.NULL, new Vec3(x, y, z), Vec2.ZERO, level,
      LevelBasedPermissionSet.OWNER, "", Component.literal(""), level.getServer(), (Entity)null);
  }
}
