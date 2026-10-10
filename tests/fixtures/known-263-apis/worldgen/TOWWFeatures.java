import net.minecraft.core.registries.Registries;
import net.minecraft.world.level.levelgen.feature.Feature;
import net.neoforged.neoforge.registries.DeferredHolder;
import net.neoforged.neoforge.registries.DeferredRegister;

class TOWWFeatures {
  static final DeferredRegister<Feature<?>> REGISTRY = DeferredRegister.create(Registries.FEATURE, "toww");
  static final DeferredHolder<Feature<?>, Feature<?>> FEATURE = REGISTRY.register("feature", TOWWFeature::new);
}
