package core3D
{
	import flash.geom.*;
	import flash.display.BitmapData;
	
	/**
	* Author: Lin Minjiang	
	* Creates an emitter to emit copies of meshes specified by given mesh
	* Supports up to 60 copies of given mesh in a single mesh
	* Primarily to support massive numbers of projectiles on stage
	*/
	public class BatchMeshes
	{
		public var skin:Mesh;					// to be added to display list for render
		public var MData:Vector.<VertexData>;	// position, orientation, and scaling and of each mesh
		public var renderCnts:Vector.<int>;		// number to render for each different geometry
		public var triCnts:Vector.<int>;		// number to triangles per different geometry
		public var numLiveParticles:uint=0;		// number of live meshes to render
		
		private var _init:Function = null;
		
		/**
		* creates a 60 batch rendered meshes group arranged 0,1,2,...n,0,1,2,...n,
		*/
		public function BatchMeshes(M:Vector.<Mesh>,compress:Boolean=true) : void
		{
			if (M==null || M.length==0)
			{
				Mesh.debugTrace("BatchMeshes Error! 0 Meshes input!");
				M = Vector.<Mesh>([Mesh.createCube(1,1,1)]);
			}
			
			skin = new Mesh();
			skin.setTexture(M[0].findTexture());
			skin.setSpecularMap(M[0].findSpecularMap());
			skin.setMeshes();	// set as empty
						
			_init = function():void
			{
			
			renderCnts = new Vector.<int>(M.length);
			triCnts = new Vector.<int>(M.length);
			var totalVariety:int = M.length;
			
			var i:int=0;
			var j:int=0;
			var n:uint=0;
			var m:Mesh=null;
			var totalParticles:uint=0;		// total number of particles renderable
			
			// ----- pre compress geometries  
			for (j=totalVariety-1; j>=0; j--)
			{
				m = M[j];
				if (m.getDataType()!=Mesh._typeV)	
				{
					Mesh.debugTrace("BatchMeshes Error! invalid input mesh of type:"+m.getDataType());
					m = Mesh.createTetra();
				}
				
				var nm:Mesh = new Mesh();
				nm.addChild(m);				// adding as child so that transform is applied during merge
				m = nm.mergeTree();
				if (m.vertData==null || m.idxsData==null)
				{
					Mesh.debugTrace("BatchMeshes Error! empty mesh given!");
					m = Mesh.createTetra();
				}
				if (compress) m.compressGeometry();		// reuse vertices data whenever possible
				M[j] = m;
				triCnts[j] = m.idxsData.length/3;
			}//endfor
						
			// ----- write geometries data to be batch rendered			
			var V:Vector.<Number> = new Vector.<Number>();	// vertices vector
			var I:Vector.<uint> = new Vector.<uint>();		// indices vector
			var cOff:uint=5;		// constants offset, vc5 onwards unused
			var iOff:uint=0;		// triangles indices offset
			for (i=0; i<60; i++)	// create 60 duplicate meshes
			{
				m = M[i%totalVariety];
				var oV:Vector.<Number> = m.vertData;	// vertices, normals and UV data [vx,vy,vz,nx,ny,nz,u,v, ...] can be null
				var oI:Vector.<uint> = m.idxsData;		// indices to vertices forming triangles [a1,a2,a3, b1,b2,b3, ...]	
				
				if (V.length/10+oV.length/8<21000)		// if still can fit more
				{
					j=0;
					n=oV.length;
					while (j<n)			// append to main V	
					{
						V.push(	oV[j+0],oV[j+1],oV[j+2],	// vx,vy,vz
								oV[j+3],oV[j+4],oV[j+5],	// nx,ny,nz
								oV[j+6],oV[j+7],			// texU,texV,
								cOff+i*2,cOff+i*2+1);		// idx,idx+1 for orientation and positioning
						j+=8;
					}
					
					j=0;
					n=oI.length;
					while (j<n)	{I.push(oI[j]+iOff); j++;}	// append to main I
					iOff+=oV.length/8;
				
					totalParticles++;
				}
				else
				{
					Mesh.debugTrace("BatchMeshes total renderable:"+totalParticles+"\n");
					i=60;	// end loop
				}
			}//endfor
			
			// ----- create skin mesh for this emitter --------------
			skin.setMeshes(V,I);
			
			// ----- default mesh positions -------------------------
			MData = new Vector.<VertexData>();
			for (i=0; i<totalParticles; i++)	// 60 GPU batch processed meshes
				MData.push(new VertexData());
			
			_init = null;
			}//endfunction
		}//endConstructor
		
		/**
		* sets the location, direction and scaling of next mesh derived from given transform matrix
		*/
		public function nextLocRotScale(id:uint,trans:Matrix4x4,sc:Number=1) : void
		{
			if (_init!=null) _init();
			
			id = id%renderCnts.length;
			var cnt:int = renderCnts[id];
			var idx:uint = cnt*renderCnts.length+id;
			if (idx>=MData.length)	
			{
				//Mesh.debugTrace("BatchMeshes nextLocRotScale id"+id+" renderCnt="+(cnt+1)+" exceeds total renderable by 1"); 
				return;
			}
			var md:VertexData = MData[idx];
			
			md.w = sc;						// set scale
			var quat:Vector3D = trans.rotationQuaternion();
			md.nx=quat.x;					// set quaternion 
			md.ny=quat.y;
			md.nz=quat.z;
			md.vx=trans.ad;					// set location
			md.vy=trans.bd;
			md.vz=trans.cd;
			
			var pcnt:int = cnt*renderCnts.length+id+1;
			if (pcnt<=MData.length && pcnt>numLiveParticles)	numLiveParticles = pcnt;
			renderCnts[id]++;
		}//endfunction
					
		/**
		* set the Loc Rot Scale directly for next mesh
		*/
		public function nextLocDirScale(id:uint,
										px:Number,py:Number,pz:Number,	// position
										dx:Number,dy:Number,dz:Number,	// direction
										sc:Number=1) : void				// scale
		{
			if (_init!=null) _init();
			
			id = id%renderCnts.length;
			var cnt:int = renderCnts[id];
			var idx:uint = cnt*renderCnts.length+id;
			if (idx>=MData.length)	return;
			var md:VertexData = MData[idx];
			
			var dl:Number = dx*dx+dy*dy+dz*dz;
			if (dl>0)
			{
				dl = Math.sqrt(dl);
				dx/=dl; dy/=dl; dz/=dl;	// normalized direction vector
				var ax:Number =-dy;
				var ay:Number = dx;
				var al:Number = Math.sqrt(ax*ax+ay*ay);
				if (al<0.000001)	
				{
					md.nx=0; 				// quaternion qx
					md.ny=0;				// quaternion qy
					md.nz=0;				// quaternion qz
				}
				else
				{
					ax/=al; ay/=al;			// rotation axis normalized
					var sinA_2:Number = Math.sqrt((1-dz)/2);	// double angle formula, cosA=dz
					md.nx=ax*sinA_2; 		// quaternion qx
					md.ny=ay*sinA_2;		// quaternion qy
					md.nz=0;				// quaternion qz
				}
			}
			else	
			{md.nx=0; md.ny=0; md.nz=1;}
			
			md.vx = px;
			md.vy = py;
			md.vz = pz;
			md.w = sc;
			
			var pcnt:int = cnt*renderCnts.length+id+1;
			if (pcnt<=MData.length && pcnt>numLiveParticles)	numLiveParticles = pcnt;
			renderCnts[id]++;
		}//endfunction
		
		/**
		* sets the scale of all the meshes to 0
		*/
		public function reset() : void
		{
			if (numLiveParticles==0) return;
			
			for (var i:int=numLiveParticles-1; i>=0; i--)
				MData[i].w = 0;	// set each particle scale invisibly small
			for (i=renderCnts.length-1; i>=0; i--)
				renderCnts[i]=0;
			numLiveParticles=0;
		}//endfunction
				
		/**
		* updates the meshes positions, send data to renderer
		*/
		public function update() : void
		{
			if (numLiveParticles==0)
			{
				skin.jointsData=null;
				return;
			}
						
			// ----- write particles positions data -----------------
			var T:Vector.<Number> = new Vector.<Number>();
			for (var i:int=0; i<numLiveParticles; i++)	
			{
				var m:VertexData = MData[i];
				T.push(m.nx,m.ny,m.nz,m.w);		// nx,ny,nz	quaternion + scale
				T.push(m.vx,m.vy,m.vz,0);		// vx,vy,vz	translation
			}
			
			// ----- calculate num tris to draw and send orientation data
			var cnt:int=0;
			for (i=0; i<numLiveParticles; i++)
				cnt+=triCnts[i%triCnts.length];
			skin.trisCnt = cnt;
			skin.jointsData = T;		// send meshes transforms to mesh for GPU transformation
		}//endfuntcion
	}//endclass
}//endpackage