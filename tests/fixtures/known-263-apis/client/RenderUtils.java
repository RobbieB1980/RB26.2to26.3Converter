package net.mcreator.robmod.client;

import com.mojang.blaze3d.PrimitiveTopology;
import com.mojang.blaze3d.buffers.GpuBuffer;
import com.mojang.blaze3d.buffers.GpuBufferSlice;
import com.mojang.blaze3d.systems.RenderPass;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.systems.RenderSystem.AutoStorageIndexBuffer;
import com.mojang.blaze3d.textures.GpuTextureView;
import com.mojang.blaze3d.vertex.BufferBuilder;
import com.mojang.blaze3d.vertex.ByteBufferBuilder;
import com.mojang.blaze3d.vertex.DefaultVertexFormat;
import com.mojang.blaze3d.vertex.MeshData;
import com.mojang.blaze3d.vertex.PoseStack;
import com.mojang.blaze3d.vertex.VertexFormat;
import com.mojang.math.Axis;
import java.util.Optional;
import java.util.OptionalDouble;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.RenderPipelines;
import net.minecraft.client.renderer.state.level.SkyRenderState;
import net.minecraft.client.renderer.texture.AbstractTexture;
import net.minecraft.resources.Identifier;
import net.neoforged.neoforge.client.event.RenderLevelStageEvent.AfterSky;
import org.joml.Matrix4f;
import org.joml.Matrix4fStack;
import org.joml.Vector4f;

public class RenderUtils {
   private static GpuBuffer sunBuffer;
   private static GpuBuffer moonBuffer;
   private static GpuBuffer skyboxBuffer;

   private static void initBuffers() {
      if (sunBuffer == null) {
         sunBuffer = buildSunBuffer();
      }

      if (moonBuffer == null) {
         moonBuffer = buildMoonBuffer();
      }

      if (skyboxBuffer == null) {
         skyboxBuffer = buildSkyboxBuffer();
      }
   }

   public static void renderCustomSun(AfterSky event, Identifier textureId) {
      initBuffers();
      Minecraft mc = Minecraft.getInstance();
      PoseStack poseStack = event.getPoseStack();
      SkyRenderState state = event.getLevelRenderState().skyRenderState;
      poseStack.pushPose();
      poseStack.mulPose(Axis.YP.rotationDegrees(-90.0F));
      poseStack.mulPose(Axis.XP.rotation(state.sunAngle));
      Matrix4fStack modelViewStack = RenderSystem.getModelViewStack();
      modelViewStack.pushMatrix();
      modelViewStack.mul(poseStack.last().pose());
      modelViewStack.translate(0.0F, 100.0F, 0.0F);
      modelViewStack.scale(30.0F, 1.0F, 30.0F);
      GpuBufferSlice dynamicTransforms = RenderSystem.getDynamicUniforms()
         .writeTransform(new Matrix4f(modelViewStack), new Vector4f(1.0F, 1.0F, 1.0F, state.rainBrightness));
      GpuTextureView color = mc.gameRenderer.mainRenderTarget().getColorTextureView();
      GpuTextureView depth = mc.gameRenderer.mainRenderTarget().getDepthTextureView();
      AutoStorageIndexBuffer sequential = RenderSystem.getSequentialBuffer(PrimitiveTopology.QUADS);
      GpuBuffer indexBuffer = sequential.getBuffer(6);
      AbstractTexture texture = mc.getTextureManager().getTexture(textureId);
      RenderPass renderPass = RenderSystem.getDevice()
         .createCommandEncoder()
         .createRenderPass(() -> "robmod Sun", color, Optional.empty(), depth, OptionalDouble.empty());

      try {
         renderPass.setPipeline(RenderPipelines.CELESTIAL);
         RenderSystem.bindDefaultUniforms(renderPass);
         renderPass.setUniform("DynamicTransforms", dynamicTransforms);
         renderPass.bindTexture("Sampler0", texture.getTextureView(), texture.getSampler());
         renderPass.setVertexBuffer(0, sunBuffer.slice());
         renderPass.setIndexBuffer(indexBuffer, sequential.type());
         renderPass.drawIndexed(6, 1, 0, 0, 0);
      } catch (Throwable var16) {
         if (renderPass != null) {
            try {
               renderPass.close();
            } catch (Throwable var15) {
               var16.addSuppressed(var15);
            }
         }

         throw var16;
      }

      if (renderPass != null) {
         renderPass.close();
      }

      modelViewStack.popMatrix();
      poseStack.popPose();
   }

   public static void renderCustomMoon(AfterSky event, Identifier textureId) {
      initBuffers();
      Minecraft mc = Minecraft.getInstance();
      PoseStack poseStack = event.getPoseStack();
      SkyRenderState state = event.getLevelRenderState().skyRenderState;
      poseStack.pushPose();
      poseStack.mulPose(Axis.YP.rotationDegrees(-90.0F));
      poseStack.mulPose(Axis.XP.rotation(state.moonAngle));
      Matrix4fStack modelViewStack = RenderSystem.getModelViewStack();
      modelViewStack.pushMatrix();
      modelViewStack.mul(poseStack.last().pose());
      modelViewStack.translate(0.0F, 100.0F, 0.0F);
      modelViewStack.scale(20.0F, 1.0F, 20.0F);
      GpuBufferSlice dynamicTransforms = RenderSystem.getDynamicUniforms()
         .writeTransform(new Matrix4f(modelViewStack), new Vector4f(1.0F, 1.0F, 1.0F, state.rainBrightness));
      GpuTextureView color = mc.gameRenderer.mainRenderTarget().getColorTextureView();
      GpuTextureView depth = mc.gameRenderer.mainRenderTarget().getDepthTextureView();
      AutoStorageIndexBuffer sequential = RenderSystem.getSequentialBuffer(PrimitiveTopology.QUADS);
      GpuBuffer indexBuffer = sequential.getBuffer(6);
      AbstractTexture texture = mc.getTextureManager().getTexture(textureId);
      int baseVertex = state.moonPhase.index() * 4;
      RenderPass renderPass = RenderSystem.getDevice()
         .createCommandEncoder()
         .createRenderPass(() -> "robmod Moon", color, Optional.empty(), depth, OptionalDouble.empty());

      try {
         renderPass.setPipeline(RenderPipelines.CELESTIAL);
         RenderSystem.bindDefaultUniforms(renderPass);
         renderPass.setUniform("DynamicTransforms", dynamicTransforms);
         renderPass.bindTexture("Sampler0", texture.getTextureView(), texture.getSampler());
         renderPass.setVertexBuffer(0, moonBuffer.slice());
         renderPass.setIndexBuffer(indexBuffer, sequential.type());
         renderPass.drawIndexed(6, 1, 0, baseVertex, 0);
      } catch (Throwable var17) {
         if (renderPass != null) {
            try {
               renderPass.close();
            } catch (Throwable var16) {
               var17.addSuppressed(var16);
            }
         }

         throw var17;
      }

      if (renderPass != null) {
         renderPass.close();
      }

      modelViewStack.popMatrix();
      poseStack.popPose();
   }

   public static void renderCustomSkybox(AfterSky event, Identifier textureId, int color, float alpha) {
      initBuffers();
      Minecraft mc = Minecraft.getInstance();
      PoseStack poseStack = event.getPoseStack();
      Matrix4fStack modelViewStack = RenderSystem.getModelViewStack();
      modelViewStack.pushMatrix();
      modelViewStack.mul(poseStack.last().pose());
      float[] rgba = getRGBA(color, alpha);
      GpuBufferSlice dynamicTransforms = RenderSystem.getDynamicUniforms()
         .writeTransform(new Matrix4f(modelViewStack), new Vector4f(rgba[0], rgba[1], rgba[2], rgba[3]));
      GpuTextureView colorTexture = mc.gameRenderer.mainRenderTarget().getColorTextureView();
      GpuTextureView depth = mc.gameRenderer.mainRenderTarget().getDepthTextureView();
      AutoStorageIndexBuffer sequential = RenderSystem.getSequentialBuffer(PrimitiveTopology.QUADS);
      GpuBuffer indexBuffer = sequential.getBuffer(36);
      AbstractTexture texture = mc.getTextureManager().getTexture(textureId);
      RenderPass renderPass = RenderSystem.getDevice()
         .createCommandEncoder()
         .createRenderPass(() -> "robmod Skybox", colorTexture, Optional.empty(), depth, OptionalDouble.empty());

      try {
         renderPass.setPipeline(RenderPipelines.END_SKY);
         RenderSystem.bindDefaultUniforms(renderPass);
         renderPass.setUniform("DynamicTransforms", dynamicTransforms);
         renderPass.bindTexture("Sampler0", texture.getTextureView(), texture.getSampler());
         renderPass.setVertexBuffer(0, skyboxBuffer.slice());
         renderPass.setIndexBuffer(indexBuffer, sequential.type());
         renderPass.drawIndexed(36, 1, 0, 0, 0);
      } catch (Throwable var18) {
         if (renderPass != null) {
            try {
               renderPass.close();
            } catch (Throwable var17) {
               var18.addSuppressed(var17);
            }
         }

         throw var18;
      }

      if (renderPass != null) {
         renderPass.close();
      }

      modelViewStack.popMatrix();
   }

   private static GpuBuffer buildSunBuffer() {
      VertexFormat format = DefaultVertexFormat.POSITION_TEX;
      ByteBufferBuilder byteBufferBuilder = ByteBufferBuilder.exactlySized(4 * format.getVertexSize());

      GpuBuffer var4;
      try {
         BufferBuilder bufferBuilder = new BufferBuilder(byteBufferBuilder, PrimitiveTopology.QUADS, format);
         bufferBuilder.addVertex(-1.0F, 0.0F, -1.0F).setUv(0.0F, 0.0F);
         bufferBuilder.addVertex(1.0F, 0.0F, -1.0F).setUv(1.0F, 0.0F);
         bufferBuilder.addVertex(1.0F, 0.0F, 1.0F).setUv(1.0F, 1.0F);
         bufferBuilder.addVertex(-1.0F, 0.0F, 1.0F).setUv(0.0F, 1.0F);
         MeshData mesh = bufferBuilder.buildOrThrow();

         try {
            var4 = RenderSystem.getDevice().createBuffer(() -> "robmod Sun", 32, mesh.vertexBuffer());
         } catch (Throwable var8) {
            if (mesh != null) {
               try {
                  mesh.close();
               } catch (Throwable var7) {
                  var8.addSuppressed(var7);
               }
            }

            throw var8;
         }

         if (mesh != null) {
            mesh.close();
         }
      } catch (Throwable var9) {
         if (byteBufferBuilder != null) {
            try {
               byteBufferBuilder.close();
            } catch (Throwable var6) {
               var9.addSuppressed(var6);
            }
         }

         throw var9;
      }

      if (byteBufferBuilder != null) {
         byteBufferBuilder.close();
      }

      return var4;
   }

   private static GpuBuffer buildMoonBuffer() {
      VertexFormat format = DefaultVertexFormat.POSITION_TEX;
      ByteBufferBuilder byteBufferBuilder = ByteBufferBuilder.exactlySized(32 * format.getVertexSize());

      GpuBuffer var15;
      try {
         BufferBuilder bufferBuilder = new BufferBuilder(byteBufferBuilder, PrimitiveTopology.QUADS, format);

         for (int k = 0; k < 8; k++) {
            int l = k % 4;
            int i1 = k / 4 % 2;
            float f13 = l / 4.0F;
            float f14 = i1 / 2.0F;
            float f15 = (l + 1) / 4.0F;
            float f16 = (i1 + 1) / 2.0F;
            bufferBuilder.addVertex(-1.0F, 0.0F, -1.0F).setUv(f15, f16);
            bufferBuilder.addVertex(1.0F, 0.0F, -1.0F).setUv(f13, f16);
            bufferBuilder.addVertex(1.0F, 0.0F, 1.0F).setUv(f13, f14);
            bufferBuilder.addVertex(-1.0F, 0.0F, 1.0F).setUv(f15, f14);
         }

         MeshData mesh = bufferBuilder.buildOrThrow();

         try {
            var15 = RenderSystem.getDevice().createBuffer(() -> "robmod Moon", 32, mesh.vertexBuffer());
         } catch (Throwable var12) {
            if (mesh != null) {
               try {
                  mesh.close();
               } catch (Throwable var11) {
                  var12.addSuppressed(var11);
               }
            }

            throw var12;
         }

         if (mesh != null) {
            mesh.close();
         }
      } catch (Throwable var13) {
         if (byteBufferBuilder != null) {
            try {
               byteBufferBuilder.close();
            } catch (Throwable var10) {
               var13.addSuppressed(var10);
            }
         }

         throw var13;
      }

      if (byteBufferBuilder != null) {
         byteBufferBuilder.close();
      }

      return var15;
   }

   private static GpuBuffer buildSkyboxBuffer() {
      VertexFormat format = DefaultVertexFormat.POSITION_TEX_COLOR;
      ByteBufferBuilder byteBufferBuilder = ByteBufferBuilder.exactlySized(24 * format.getVertexSize());

      GpuBuffer var7;
      try {
         BufferBuilder bufferBuilder = new BufferBuilder(byteBufferBuilder, PrimitiveTopology.QUADS, format);
         float distance = 100.0F;
         float size = 100.0F;
         int color = -1;
         addSkyboxFace(
            bufferBuilder,
            -size,
            distance,
            -size,
            0.25F,
            0.33333334F,
            size,
            distance,
            -size,
            0.5F,
            0.33333334F,
            size,
            distance,
            size,
            0.5F,
            0.0F,
            -size,
            distance,
            size,
            0.25F,
            0.0F,
            color
         );
         addSkyboxFace(
            bufferBuilder,
            -size,
            -distance,
            -size,
            0.25F,
            0.6666667F,
            -size,
            -distance,
            size,
            0.25F,
            1.0F,
            size,
            -distance,
            size,
            0.5F,
            1.0F,
            size,
            -distance,
            -size,
            0.5F,
            0.6666667F,
            color
         );
         addSkyboxFace(
            bufferBuilder,
            -distance,
            -size,
            size,
            0.0F,
            0.6666667F,
            -distance,
            -size,
            -size,
            0.25F,
            0.6666667F,
            -distance,
            size,
            -size,
            0.25F,
            0.33333334F,
            -distance,
            size,
            size,
            0.0F,
            0.33333334F,
            color
         );
         addSkyboxFace(
            bufferBuilder,
            -size,
            -size,
            -distance,
            0.25F,
            0.6666667F,
            size,
            -size,
            -distance,
            0.5F,
            0.6666667F,
            size,
            size,
            -distance,
            0.5F,
            0.33333334F,
            -size,
            size,
            -distance,
            0.25F,
            0.33333334F,
            color
         );
         addSkyboxFace(
            bufferBuilder,
            distance,
            -size,
            -size,
            0.5F,
            0.6666667F,
            distance,
            -size,
            size,
            0.75F,
            0.6666667F,
            distance,
            size,
            size,
            0.75F,
            0.33333334F,
            distance,
            size,
            -size,
            0.5F,
            0.33333334F,
            color
         );
         addSkyboxFace(
            bufferBuilder,
            size,
            -size,
            distance,
            0.75F,
            0.6666667F,
            -size,
            -size,
            distance,
            1.0F,
            0.6666667F,
            -size,
            size,
            distance,
            1.0F,
            0.33333334F,
            size,
            size,
            distance,
            0.75F,
            0.33333334F,
            color
         );
         MeshData meshData = bufferBuilder.buildOrThrow();

         try {
            var7 = RenderSystem.getDevice().createBuffer(() -> "robmod Skybox", 40, meshData.vertexBuffer());
         } catch (Throwable var11) {
            if (meshData != null) {
               try {
                  meshData.close();
               } catch (Throwable var10) {
                  var11.addSuppressed(var10);
               }
            }

            throw var11;
         }

         if (meshData != null) {
            meshData.close();
         }
      } catch (Throwable var12) {
         if (byteBufferBuilder != null) {
            try {
               byteBufferBuilder.close();
            } catch (Throwable var9) {
               var12.addSuppressed(var9);
            }
         }

         throw var12;
      }

      if (byteBufferBuilder != null) {
         byteBufferBuilder.close();
      }

      return var7;
   }

   private static void addSkyboxFace(
      BufferBuilder bufferBuilder,
      float x1,
      float y1,
      float z1,
      float u1,
      float v1,
      float x2,
      float y2,
      float z2,
      float u2,
      float v2,
      float x3,
      float y3,
      float z3,
      float u3,
      float v3,
      float x4,
      float y4,
      float z4,
      float u4,
      float v4,
      int color
   ) {
      bufferBuilder.addVertex(x1, y1, z1).setUv(u1, v1).setColor(color);
      bufferBuilder.addVertex(x2, y2, z2).setUv(u2, v2).setColor(color);
      bufferBuilder.addVertex(x3, y3, z3).setUv(u3, v3).setColor(color);
      bufferBuilder.addVertex(x4, y4, z4).setUv(u4, v4).setColor(color);
   }

   public static float[] getRGBA(int hexColor, float alpha) {
      return new float[]{(hexColor >> 16 & 0xFF) / 255.0F, (hexColor >> 8 & 0xFF) / 255.0F, (hexColor & 0xFF) / 255.0F, alpha};
   }
}