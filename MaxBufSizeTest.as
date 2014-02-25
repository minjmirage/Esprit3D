package 
{
	import flash.text.*;
	import flash.geom.*;
	import flash.utils.*;
	import flash.events.*;
	import flash.filters.*;
	import flash.display3D.*;
	import flash.display.*;
	
	import core3D.*;
	
	[SWF(backgroundColor="#FFFFFF", frameRate="30", width="960", height="640")]
	public class MaxBufSizeTest extends Sprite
	{
		private var debugTf:TextField = null;
		
		public function MaxBufSizeTest(): void
		{
			debugTf = new TextField();
			debugTf.width = stage.stageWidth;
			debugTf.height = stage.stageHeight;
			addChild(debugTf);
			debugTf.text = "MaxBufSizeTest()\n";
			
			Mesh.getContext(stage,onContext);
		
		}//endfunction
		
		public function onContext() : void
		{
			var numVertices:int = 65535;
			try {
				var vertexBuffer:VertexBuffer3D = Mesh.context3d.createVertexBuffer(numVertices, 64);	// vx,vy,vz,nx,ny,nz,u,v
				debugTf.appendText("Created vertexBuffer numVertices="+numVertices+"\n");
				var R:Vector.<Number> = new Vector.<Number>();
				debugTf.appendText("??\n");
				for (var i:int=0; i<numVertices*64; i++)	R.push(i);
				debugTf.appendText("here!\n");
				
				vertexBuffer.uploadFromVector(R,0, numVertices);
				debugTf.appendText("Uploaded R.lrngth="+R.length+"\n");
				
			} 
			catch (e:Error) 
			{
				debugTf.appendText("Error!"+e);
			}
		}
	}//endclass
}//endpackage