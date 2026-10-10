package net.mcreator.robmod;

import it.unimi.dsi.fastutil.ints.IntObjectImmutablePair;
import it.unimi.dsi.fastutil.ints.IntObjectPair;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Map;
import java.util.PriorityQueue;
import java.util.Queue;
import java.util.concurrent.ConcurrentLinkedQueue;
import javax.annotation.Nullable;
import net.mcreator.robmod.init.RobmodModBlocks;
import net.mcreator.robmod.init.RobmodModItems;
import net.mcreator.robmod.init.RobmodModTabs;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.codec.StreamCodec;
import net.minecraft.network.protocol.common.custom.CustomPacketPayload;
import net.minecraft.network.protocol.common.custom.CustomPacketPayload.Type;
import net.minecraft.server.TickTask;
import net.minecraft.world.entity.player.Player;
import net.neoforged.bus.api.IEventBus;
import net.neoforged.bus.api.SubscribeEvent;
import net.neoforged.fml.common.Mod;
import net.neoforged.fml.loading.FMLEnvironment;
import net.neoforged.fml.util.thread.SidedThreadGroups;
import net.neoforged.neoforge.common.NeoForge;
import net.neoforged.neoforge.event.tick.ServerTickEvent.Post;
import net.neoforged.neoforge.network.event.RegisterPayloadHandlersEvent;
import net.neoforged.neoforge.network.handling.IPayloadHandler;
import net.neoforged.neoforge.network.registration.PayloadRegistrar;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

@Mod("robmod")
public class RobmodMod {
   public static final Logger LOGGER = LogManager.getLogger(RobmodMod.class);
   public static final String MODID = "robmod";
   private static boolean networkingRegistered = false;
   private static final Map<Type<?>, RobmodMod.NetworkMessage<?>> MESSAGES = new HashMap<>();
   private static final Queue<IntObjectPair<Runnable>> workToBeScheduled = new ConcurrentLinkedQueue<>();
   private static final PriorityQueue<TickTask> workQueue = new PriorityQueue<>(Comparator.comparingInt(TickTask::getTick));
   private static Object minecraft;
   private static MethodHandle playerHandle;

   public RobmodMod(IEventBus modEventBus) {
      NeoForge.EVENT_BUS.register(this);
      modEventBus.addListener(this::registerNetworking);
      RobmodModBlocks.REGISTRY.register(modEventBus);
      RobmodModItems.REGISTRY.register(modEventBus);
      RobmodModTabs.REGISTRY.register(modEventBus);
   }

   public static <T extends CustomPacketPayload> void addNetworkMessage(
      Type<T> id, StreamCodec<? extends FriendlyByteBuf, T> reader, IPayloadHandler<T> handler
   ) {
      if (networkingRegistered) {
         throw new IllegalStateException("Cannot register new network messages after networking has been registered");
      }

      MESSAGES.put(id, new RobmodMod.NetworkMessage(reader, handler));
   }

   private void registerNetworking(RegisterPayloadHandlersEvent event) {
      PayloadRegistrar registrar = event.registrar("robmod");
      MESSAGES.forEach((id, networkMessage) -> registrar.playBidirectional(id, networkMessage.reader(), networkMessage.handler(), networkMessage.handler()));
      networkingRegistered = true;
   }

   public static void queueServerWork(int delay, Runnable action) {
      if (Thread.currentThread().getThreadGroup() == SidedThreadGroups.SERVER) {
         workToBeScheduled.add(new IntObjectImmutablePair(delay, action));
      }
   }

   @SubscribeEvent
   public void tick(Post event) {
      int currentTick = event.getServer().getTickCount();

      IntObjectPair<Runnable> work;
      while ((work = workToBeScheduled.poll()) != null) {
         workQueue.add(new TickTask(currentTick + work.leftInt(), (Runnable)work.right()));
      }

      while (!workQueue.isEmpty() && currentTick >= workQueue.peek().getTick()) {
         workQueue.poll().run();
      }
   }

   @Nullable
   public static Player clientPlayer() {
      if (!FMLEnvironment.getDist().isClient()) {
         return null;
      }

      try {
         if (minecraft == null || playerHandle == null) {
            Class<?> minecraftClass = Class.forName("net.minecraft.client.Minecraft");
            minecraft = (Object)MethodHandles.publicLookup().findStatic(minecraftClass, "getInstance", MethodType.methodType(minecraftClass)).invoke();
            playerHandle = MethodHandles.publicLookup().findGetter(minecraftClass, "player", Class.forName("net.minecraft.client.player.LocalPlayer"));
         }

         return (Player)playerHandle.invoke((Object)minecraft);
      } catch (Throwable e) {
         LOGGER.error("Failed to get client player", e);
         return null;
      }
   }

   private record NetworkMessage<T extends CustomPacketPayload>(StreamCodec<? extends FriendlyByteBuf, T> reader, IPayloadHandler<T> handler) {
   }
}