import java.nio.file.*;
import java.util.*;
import com.github.javaparser.*;
import com.github.javaparser.ast.*;
import com.github.javaparser.ast.body.*;
import com.github.javaparser.ast.expr.*;
import com.github.javaparser.ast.stmt.*;
import com.github.javaparser.ast.type.*;

/** Narrow AST rules verified against Minecraft/NeoForge 26.3.0.22-beta. */
class Known263Apis {
 static boolean imported(CompilationUnit c,String name){return c.getImports().stream().anyMatch(i->i.getNameAsString().equals(name));}
 static String scope(MethodCallExpr m){return m.getScope().map(Object::toString).orElse("");}
 static final Map<String,String> MOVED=Map.of(
  "com.mojang.blaze3d.PrimitiveTopology","com.mojang.renderpearl.api.pipeline.PrimitiveTopology",
  "com.mojang.blaze3d.buffers.GpuBuffer","com.mojang.renderpearl.api.buffers.GpuBuffer",
  "com.mojang.blaze3d.buffers.GpuBufferSlice","com.mojang.renderpearl.api.buffers.GpuBufferSlice",
  "com.mojang.blaze3d.systems.RenderPass","com.mojang.renderpearl.api.commands.RenderPass",
  "com.mojang.blaze3d.textures.GpuTextureView","com.mojang.renderpearl.api.textures.GpuTextureView",
  "com.mojang.blaze3d.vertex.VertexFormat","com.mojang.renderpearl.api.vertex.VertexFormat");
 static boolean render(CompilationUnit c){
  if(!imported(c,"com.mojang.blaze3d.buffers.GpuBuffer") || c.getClassByName("RenderUtils").isEmpty())return false;
  var cls=c.getClassByName("RenderUtils").get();
  if(!List.of("renderCustomSun","renderCustomMoon","renderCustomSkybox").stream().allMatch(n->cls.getMethodsByName(n).size()==1))return false;
  var calls=c.findAll(MethodCallExpr.class);
  var transforms=calls.stream().filter(m->m.getNameAsString().equals("writeTransform")).toList();
  var pipelines=calls.stream().filter(m->m.getNameAsString().equals("setPipeline")&&scope(m).equals("renderPass")).toList();
  var textures=calls.stream().filter(m->m.getNameAsString().equals("bindTexture")&&scope(m).equals("renderPass")).toList();
  var rotations=calls.stream().filter(m->m.getNameAsString().equals("mulPose")&&scope(m).equals("poseStack")).toList();
  if(transforms.size()!=3||pipelines.size()!=3||textures.size()!=3||rotations.size()!=4)return false;
  for(var m:transforms)if(!scope(m).equals("RenderSystem.getDynamicUniforms()") || !(m.getArguments().size()==2 || (m.getArguments().size()==4 && m.getArgument(2).toString().equals("new Vector3f()") && m.getArgument(3).toString().equals("new Matrix4f()"))))return false;
  for(var m:pipelines)if(m.getArguments().size()!=1 || !Set.of("RenderPipelines.CELESTIAL","RenderPipelines.END_SKY").contains(m.getArgument(0).toString()))return false;
  for(var m:textures)if(m.getArguments().size()!=3 || !m.getArgument(0).toString().equals("\"Sampler0\""))return false;
  for(var m:rotations)if(m.getArguments().size()!=1 || !m.getArgument(0).toString().startsWith("Axis."))return false;
  c.getImports().forEach(i->{String n=MOVED.get(i.getNameAsString());if(n!=null)i.setName(n);});
  for(var m:transforms)if(m.getArguments().size()==4){m.getArguments().remove(3);m.getArguments().remove(2);}
  for(var m:pipelines)m.setArgument(0,new MethodCallExpr(new NameExpr("RenderSystem"),"getCompiledPipeline",new NodeList<>(m.getArgument(0).clone())));
  textures.forEach(m->m.setName("setUniform"));rotations.forEach(m->m.setName("rotate"));
  return true;
 }
 static boolean networking(CompilationUnit c){
  if(!imported(c,"net.minecraft.network.FriendlyByteBuf")||!imported(c,"net.neoforged.neoforge.network.registration.PayloadRegistrar"))return false;
  var records=c.findAll(RecordDeclaration.class).stream().filter(r->r.getNameAsString().equals("NetworkMessage")).toList();
  var adds=c.findAll(MethodDeclaration.class).stream().filter(m->m.getNameAsString().equals("addNetworkMessage")).toList();
  var regs=c.findAll(MethodDeclaration.class).stream().filter(m->m.getNameAsString().equals("registerNetworking")).toList();
  if(records.size()!=1||adds.size()!=1||regs.size()!=1)return false;
  var record=records.get(0);var add=adds.get(0);var reg=regs.get(0);
  if(record.getParameters().size()!=2||!record.getMembers().isEmpty()||add.getParameters().size()!=3)return false;
  if(!record.getParameter(0).getType().toString().equals("StreamCodec<? extends FriendlyByteBuf, T>")||!add.getParameter(1).getType().toString().equals("StreamCodec<? extends FriendlyByteBuf, T>"))return false;
  var constructs=add.findAll(ObjectCreationExpr.class).stream().filter(n->n.getType().getNameAsString().equals("NetworkMessage")).toList();
  var loops=reg.findAll(ExpressionStmt.class).stream().filter(s->s.toString().startsWith("MESSAGES.forEach")).toList();
  if(constructs.size()!=1||loops.size()!=1||!constructs.get(0).getArguments().toString().equals("[reader, handler]"))return false;
  String expected="MESSAGES.forEach((id, networkMessage) -> registrar.playBidirectional(id, networkMessage.reader(), networkMessage.handler(), networkMessage.handler()));";
  if(!loops.get(0).equals(StaticJavaParser.parseStatement(expected)))return false;
  c.addImport("net.minecraft.network.RegistryFriendlyByteBuf");
  add.getParameter(1).setType(StaticJavaParser.parseType("StreamCodec<? super RegistryFriendlyByteBuf, T>"));
  constructs.get(0).replace(StaticJavaParser.parseExpression("new NetworkMessage<>(id, reader, handler)"));
  loops.get(0).replace(StaticJavaParser.parseStatement("MESSAGES.values().forEach(message -> message.register(registrar));"));
  record.replace(StaticJavaParser.parseBodyDeclaration("private record NetworkMessage<T extends CustomPacketPayload>(Type<T> id, StreamCodec<? super RegistryFriendlyByteBuf, T> reader, IPayloadHandler<T> handler) { void register(PayloadRegistrar registrar) { registrar.playBidirectional(id, reader, handler, handler); } }"));
  return true;
 }
 static boolean doors(CompilationUnit c){
  if(!imported(c,"net.minecraft.world.level.material.PushReaction")||!imported(c,"net.minecraft.world.level.block.DoorBlock"))return false;
  boolean changed=false;
  for(var cls:c.findAll(ClassOrInterfaceDeclaration.class)){
   if(cls.getExtendedTypes().stream().noneMatch(t->t.getNameAsString().equals("DoorBlock")))continue;
   for(var m:cls.findAll(MethodCallExpr.class))if(m.getNameAsString().equals("pushReaction") && m.getArguments().size()==1 && m.getArgument(0).toString().equals("PushReaction.DESTROY")){
    m.setArgument(0,StaticJavaParser.parseExpression("PushReaction.POPPED"));changed=true;
   }
  }
  return changed;
 }
 static boolean towwFeature(CompilationUnit c){
  if(!imported(c,"net.minecraft.world.level.levelgen.feature.FeaturePlaceContext")&&!c.toString().contains("extends Feature<NoneFeatureConfiguration>"))return false;
  boolean changed=false;
  c.getImports().removeIf(i->i.getNameAsString().equals("net.minecraft.world.level.levelgen.feature.FeaturePlaceContext")||i.getNameAsString().equals("net.minecraft.world.level.levelgen.feature.configurations.NoneFeatureConfiguration"));
  c.addImport("com.mojang.serialization.MapCodec");c.addImport("net.minecraft.util.RandomSource");c.addImport("net.minecraft.world.level.WorldGenLevel");c.addImport("net.minecraft.world.level.chunk.ChunkGenerator");
  for(var cls:c.findAll(ClassOrInterfaceDeclaration.class)){
   if(cls.getExtendedTypes().stream().noneMatch(t->t.getNameAsString().equals("Feature")))continue;
   cls.getExtendedTypes().removeIf(t->t.getNameAsString().equals("Feature"));cls.addImplementedType("Feature");
   cls.getConstructors().stream().filter(k->k.getBody().toString().contains("NoneFeatureConfiguration.CODEC")).forEach(k->k.getBody().getStatements().removeIf(s->s.toString().contains("super(NoneFeatureConfiguration.CODEC)")));
   for(var method:cls.getMethodsByName("place")){
    if(method.getParameters().size()!=1||!method.getParameter(0).getType().toString().contains("FeaturePlaceContext"))continue;
    method.setParameters(NodeList.nodeList(new Parameter(StaticJavaParser.parseType("WorldGenLevel"),"level"),new Parameter(StaticJavaParser.parseType("ChunkGenerator"),"generator"),new Parameter(StaticJavaParser.parseType("RandomSource"),"random"),new Parameter(StaticJavaParser.parseType("BlockPos"),"origin")));
    for(var call:method.findAll(MethodCallExpr.class).stream().toList()){
     String scope=call.getScope().map(Object::toString).orElse("");
     if(scope.equals("context")&&call.getArguments().isEmpty()&&Set.of("level","random","origin").contains(call.getNameAsString()))call.replace(new NameExpr(call.getNameAsString()));
     if(call.getNameAsString().equals("getStructureManager"))call.setName("getStructureTemplateManager");
    }
   }
   if(cls.getMethodsByName("codec").isEmpty()){
    String name=cls.getNameAsString();cls.addMethod("codec",Modifier.Keyword.PUBLIC).setType("MapCodec<? extends Feature>").setBody(StaticJavaParser.parseBlock("{ return MapCodec.unit("+name+"::new); }"));
   }
   changed=true;
  }
  return changed;
 }
 static boolean towwFeatureRegistry(CompilationUnit c){
  if(!c.toString().contains("DeferredRegister<Feature<?"))return false;
  boolean changed=false;for(var type:c.findAll(ClassOrInterfaceType.class))if(type.getNameAsString().equals("Feature")&&type.getTypeArguments().isPresent()){type.removeTypeArguments();changed=true;}return changed;
 }
 static boolean towwCommandSource(CompilationUnit c){
  boolean changed=false;for(var creation:c.findAll(ObjectCreationExpr.class))if(creation.getType().getNameAsString().equals("CommandSourceStack")&&creation.getArguments().size()==9&&creation.getArgument(5).toString().equals("\"\"")){creation.getArguments().remove(8);creation.getArguments().remove(5);changed=true;}return changed;
 }
 static boolean towwStateHolder(CompilationUnit c){
  boolean changed=false;for(var call:c.findAll(MethodCallExpr.class)){String scope=call.getScope().map(Object::toString).orElse("");if(call.getNameAsString().equals("setValue")&&call.getArguments().size()==2&&call.getArgument(1).toString().equals("entry.getValue()")&&scope.equals("_bs")){c.addImport("net.minecraft.world.level.block.state.StateHolder");call.setScope(StaticJavaParser.parseExpression("((StateHolder)_bs)"));changed=true;}}return changed;
 }
 public static void main(String[] args)throws Exception{
  StaticJavaParser.getParserConfiguration().setLanguageLevel(ParserConfiguration.LanguageLevel.BLEEDING_EDGE);
  Path root=Path.of(args[0]);Path source=root.resolve("src/main/java");
  if(!Files.isDirectory(source))return;
  Map<Path,String> staged=new LinkedHashMap<>();List<String> report=new ArrayList<>();
  try(var paths=Files.walk(source)){
   for(Path p:paths.filter(f->f.toString().endsWith(".java")).sorted().toList()){
     String text=Files.readString(p);if(!text.contains("PushReaction.DESTROY")&&!text.contains("blaze3d.buffers.GpuBuffer")&&!text.contains("StreamCodec<? extends FriendlyByteBuf")&&!text.contains("FeaturePlaceContext")&&!text.contains("DeferredRegister<Feature<?")&&!text.contains("new CommandSourceStack")&&!text.contains("entry.getValue()"))continue;
    CompilationUnit c;
    try{c=StaticJavaParser.parse(text);}catch(ParseProblemException ex){report.add("REVIEW parse failed: "+root.relativize(p));continue;}
     List<String> rules=new ArrayList<>();if(render(c))rules.add("renderpearl");if(networking(c))rules.add("payload-registration");if(doors(c))rules.add("door-piston-reaction");if(towwFeature(c))rules.add("toww-feature");if(towwFeatureRegistry(c))rules.add("toww-feature-registry");if(towwCommandSource(c))rules.add("toww-command-source");if(towwStateHolder(c))rules.add("toww-state-holder");
    if(!rules.isEmpty()){staged.put(p,c.toString());report.add("CHANGED "+root.relativize(p)+" : "+String.join(",",rules));}
    else report.add("REVIEW no exact rule matched: "+root.relativize(p));
   }
  }
  for(var entry:staged.entrySet())Files.writeString(entry.getKey(),entry.getValue());
  Path evidence=root.resolve(".gokuai");Files.createDirectories(evidence);
  Files.write(evidence.resolve("known-263-api-repair.txt"),report);
  report.forEach(System.out::println);System.out.println("Known 26.3 AST repairs: "+staged.size()+" files");
 }
}
