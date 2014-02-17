package core3D
{
	import flash.geom.*;
	import flash.display.BitmapData;
	
	public class RibbonTrailEffect
	{
		private var T:Vector.<Number> = null;
		public var skin:Mesh = null;
		
		private var isReset:Boolean=true;
		
		/**
		* creates a 60 segmented trail effect
		*/
		public function RibbonTrailEffect(tex:BitmapData=null) : void
		{
			// ----- init array -------------------------------------
			T = new Vector.<Number>();
			for (var i:int=0; i<120; i++)	T.push(0,0,0,0);
			
			// ----- create custom geometry data --------------------
			var vertData:Vector.<Number> = new Vector.<Number>();	// [vx,vy,vz,nx,ny,nz,u,v, ...]
			var idxsData:Vector.<uint> = new Vector.<uint>();
			var cOff:uint=5;		// constants offset, vc5 onwards unused
			var n:uint = 60;
			for (i=0; i<n; i++)
			{
				var v:Number = i/(n-1);		// tex v coordinate
				// 	forward facing
				vertData.push( -1,0,0,		// vertex
								0,-1,0,		// normal
								0,v,		// u,v
								cOff+i*2,cOff+i*2+1);	// idx,idx+1
				vertData.push(  1,0,0,		// vertex
								0,-1,0,		// normal
								1,v,		// u,v
								cOff+i*2,cOff+i*2+1);	// idx,idx+1
				// 	reverse facing
				vertData.push(  1,0,0,		// vertex
								0,1,0,		// normal
								1,v,		// u,v
								cOff+i*2,cOff+i*2+1);	// idx,idx+1
				vertData.push( -1,0,0,		// vertex
								0,1,0,		// normal
								0,v,		// u,v
								cOff+i*2,cOff+i*2+1);	// idx,idx+1
				
				idxsData.push(i*4+0,i*4+1,i*4+5);	// tri 1
				idxsData.push(i*4+0,i*4+5,i*4+4);	// tri 2
				idxsData.push(i*4+2,i*4+3,i*4+7);	// tri 3
				idxsData.push(i*4+2,i*4+7,i*4+6);	// tri 4
			}
			for (i=0; i<12; i++)	idxsData.pop();
			
			skin = new Mesh();
			skin.setMeshes(vertData,idxsData);
			skin.setTexture(tex);
			skin.setAmbient(1,1,1,0);
			skin.depthWrite = false;
			skin.castsShadow = false;
			skin.enableLighting(false);
			
		}//endfunction
		
		/**
		* updates the trail head position and orientation with this given matrix
		*/
		public function update(trans:Matrix4x4,width:Number=1) : void
		{
			if (isReset)
			{
				for (var i:int=0; i<120; i++)	T.push(trans.ad,trans.bd,trans.cd,0);
				while (T.length>120*4)			T.shift();
			}
			else
			{
				var quat:Vector3D = trans.rotationQuaternion();
				T.push(quat.x,quat.y,quat.z,width);			// quatX,quatY,quatZ,scale,
				T.push(trans.ad,trans.bd,trans.cd,0);		// transX,transY,transZ,0
				while (T.length>120*4)			T.shift();	// remove 
			}
			isReset=false;
			
			skin.jointsData = T;		// send transforms to mesh for GPU transformation
		}//endfunction
		
		/**
		* clears off current trail state and start anew
		*/
		public function reset() : void
		{
			for (var i:int=0; i<120; i++)	T.push(0,0,0,0);
			while (T.length>120*4)			T.shift();
		}//endfunction
		
	}//endClass
}