import net.minecraft.world.level.levelgen.feature.Feature;
import net.minecraft.world.level.levelgen.feature.FeaturePlaceContext;
import net.minecraft.world.level.levelgen.feature.configurations.NoneFeatureConfiguration;

class TOWWFeature extends Feature<NoneFeatureConfiguration> {
  TOWWFeature() { super(NoneFeatureConfiguration.CODEC); }
  public boolean place(FeaturePlaceContext<NoneFeatureConfiguration> context) {
    return context.random().nextBoolean() && context.origin() != null && context.level() != null
      && context.level().getLevel().getStructureManager() != null;
  }
}
