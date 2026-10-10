package net.mcreator.robmod.block;

import net.minecraft.world.level.block.DoorBlock;
import net.minecraft.world.level.block.SoundType;
import net.minecraft.world.level.block.state.BlockBehaviour.Properties;
import net.minecraft.world.level.block.state.properties.BlockSetType;
import net.minecraft.world.level.material.PushReaction;

public class Door001Block extends DoorBlock {
   public Door001Block(Properties properties) {
      super(
         BlockSetType.OAK,
         properties.sound(SoundType.WOOD).strength(1000.0F).noOcclusion().pushReaction(PushReaction.DESTROY).isRedstoneConductor((bs, br, bp) -> false)
      );
   }
}