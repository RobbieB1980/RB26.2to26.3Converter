import java.util.Map;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.StateHolder;
import net.minecraft.world.level.block.state.properties.Property;

class TOWWState {
  BlockState copy(BlockState state, BlockState target, Map.Entry<Property<?>, Comparable<?>> entry) {
    Property property = target.getBlock().getStateDefinition().getProperty(entry.getKey().getName());
    BlockState _bs = state;
    return (BlockState)_bs.setValue(property, entry.getValue());
  }
}
