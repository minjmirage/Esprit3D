package core3D
{
	import flash.geom.Vector3D;
	
	/**
	* Author: Lin Minjiang	
	* Creates an emitter to emit copies of meshes specified by given mesh
	* Supports up to 60 copies of given mesh in a single mesh
	* Primarily to support massive numbers of projectiles on stage
	*/
	public class MeshParticles
	{
		public var skin:Mesh;
				
		public var numLiveParticles:uint=0;		// number of live meshes to render
		
		public var MData:Vector.<VertexData>;	// position, orientation, and scaling and of each mesh
		private var totalParticles:uint=60;		// total number of particles renderable
		
		private var numTrisPerMesh:uint = 0;
		private var particleMesh:Mesh = null;
			
		/**
		* creates a 60 batch rendered mesh group
		*/
		public function MeshParticles(m:Mesh,compress:Boolean=true) : void
		{
			skin = m.mergeTree();
			
			
				if (m.getDataType()!=Mesh._typeV)	
				{
					Mesh.debugTrace("MeshParticles Error! invalid input mesh of type:"+m.getDataType());
					m = Mesh.createTetra();
				}
			
				var nm:Mesh = new Mesh();
				nm.addChild(m);				// adding as child so that transform is applied during merge
				m = nm.mergeTree();
				if (m.vertData==null || m.idxsData==null)
				{
					Mesh.debugTrace("MeshParticles Error! empty mesh given!");
					m = Mesh.createTetra();
				}
				if (compress) m.compressGeometry();		// reuse vertices data whenever possible
			
				var oV:Vector.<Number> = m.vertData;	// vertices, normals and UV data [vx,vy,vz,nx,ny,nz,tx,ty,tz,u,v, ...] can be null
				var oI:Vector.<uint> = m.idxsData;		// indices to vertices forming triangles [a1,a2,a3, b1,b2,b3, ...]		
						
				// ----- set as 0 drawn by default
				numLiveParticles = 0;
				numTrisPerMesh = oI.length/3;
				totalParticles = Math.min(60,65535/(oV.length/11));
				//if (totalParticles<60 && Mesh.debugTf!=null)	Mesh.debugTrace("MeshParticles total renderable:"+totalParticles+"\n");
			
				var V:Vector.<Number> = new Vector.<Number>();
				var I:Vector.<uint> = new Vector.<uint>();
				var cOff:uint=5;		// constants offset, vc5 onwards unused
				var iOff:uint=0;		// triangles indices offset
				for (var i:int=0; i<totalParticles; i++)	// create 60 duplicate meshes
				{
					var j:uint=0;
					var n:uint=oV.length;
					while (j<n)			// append to main V	
					{
						V.push(	oV[j+0],oV[j+1],oV[j+2],	// vx,vy,vz
								oV[j+3],oV[j+4],oV[j+5],	// nx,ny,nz
								oV[j+6],oV[j+7],oV[j+8],	// tx,ty,tz
								oV[j+9],oV[j+10],			// texU,texV,
								cOff+i*2,cOff+i*2+1);		// idx,idx+1 for orientation and positioning
						j+=11;
					}
				
					j=0;
					n=oI.length;
					while (j<n)	{I.push(oI[j]+iOff); j++;}	// append to main I
					iOff+=oV.length/11;
				}
						
				// ----- create skin mesh for this emitter --------------
				skin.setMeshes(V,I);
			
				// ----- default mesh positions -------------------------
				MData = new Vector.<VertexData>();
				for (i=0; i<totalParticles; i++)	// 60 GPU batch processed meshes
					MData.push(new VertexData());
			
		}//endConstructor
		
		public function get totalRenderable() : int
		{
			return totalParticles;
		}//endConstructor
		
		/**
		* returns clone of this in current state
		*/
		public function clone() : MeshParticles
		{
			var mp:MeshParticles = new MeshParticles(particleMesh);
			mp.skin = skin.clone();
			mp.totalParticles = totalParticles;
			mp.numLiveParticles = numLiveParticles;
			mp.numTrisPerMesh = numTrisPerMesh;
			mp.MData = new Vector.<VertexData>();
			for (var i:int=MData.length-1; i>=0; i--)
				mp.MData.unshift(MData[i]);
			return mp;
		}//endfunction
				
		/**
		* sets the location, direction and scaling of next mesh derived from given transform matrix
		*/
		public function nextLocRotScale(trans:Matrix4x4,sc:Number=1) : void
		{
			numLiveParticles = Math.min(MData.length,numLiveParticles+1);
			var md:VertexData = MData[numLiveParticles-1];	// the mesh particle data to alter 
			
			md.w = sc;						// set scale
			var quat:Vector3D = trans.rotationQuaternion();
			md.nx=quat.x;					// set quaternion 
			md.ny=quat.y;
			md.nz=quat.z;
			md.vx=trans.ad;					// set location
			md.vy=trans.bd;
			md.vz=trans.cd;
		}//endfunction
			
		/**
		* set the Loc Rot Scale directly for next mesh
		*/
		public function nextLocDirScale(px:Number,py:Number,pz:Number,	// position
										dx:Number,dy:Number,dz:Number,	// direction
										sc:Number=1) : void				// scale
		{
			numLiveParticles = Math.min(MData.length,numLiveParticles+1);
			var md:VertexData = MData[numLiveParticles-1];	// the mesh particle data to alter 
			
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
		}//endfunction
		
		/**
		* sets the scale of all the meshes to 0
		*/
		public function reset() : void
		{
			numLiveParticles=0;
		}//endfunction
				
		/**
		* updates the meshes positions, send data to renderer
		*/
		public function update() : void
		{
			if (numLiveParticles==0)
			{
				skin.jointsData = null;		// render disabled
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
			
			skin.trisCnt = numLiveParticles*numTrisPerMesh;
			skin.jointsData = T;		// send meshes transforms to mesh for GPU transformation
		}//endfuntcion
	}//endclass
}//endpackage