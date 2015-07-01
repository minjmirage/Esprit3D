package core3D
{
	import flash.display.Bitmap;
	import flash.display.BitmapData;
	import flash.display.BitmapDataChannel;
	import flash.display.Loader;
	import flash.display.Stage;
	import flash.display.Stage3D;
	import flash.display3D.Context3D;
	import flash.display3D.Context3DTextureFormat;
	import flash.display3D.Context3DTriangleFace;
	import flash.display3D.IndexBuffer3D;
	import flash.display3D.Program3D;
	import flash.display3D.textures.CubeTexture;
	import flash.display3D.textures.Texture;
	import flash.display3D.VertexBuffer3D;
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.filters.ColorMatrixFilter;
	import flash.geom.Matrix;
	import flash.geom.Point;
	import flash.geom.Rectangle;
	import flash.geom.Vector3D;
	import flash.net.FileReference;
	import flash.net.URLLoader;
	import flash.net.URLRequest;
	import flash.system.System;
	import flash.text.TextField;
	import flash.text.TextFormat;
	import flash.utils.ByteArray;
	import flash.utils.getTimer;

	/**
	* Unified 3D Mesh class
	* Author: Lin Minjiang	2014/04/06s	updated
	* Known Issues: No farClip, shadowMapping range too short
	*/
	public final class Mesh
	{
		public var childMeshes:Vector.<Mesh>;			// list of children meshes
		public var vertData:Vector.<Number>;			// vertices, normals and UV data [vx,vy,vz,nx,ny,nz,u,v, ...] can be null
		public var idxsData:Vector.<uint>;				// indices to vertices forming triangles [a1,a2,a3, b1,b2,b3, ...]
		public var jointsData:Vector.<Number>;			// joints position and orientation data for GPU skinning
		public var transform:Matrix4x4;					// local transform matrix of this mesh
		public var castsShadow:Boolean = true;			// specifies if this mesh geometry casts shadow
		public var useMipMapping:Boolean = false;		// specifies whether to use mipmapping to render this mesh
		public var workingTransform:Matrix4x4;			// calculated global transform for this mesh during rendering

		private var collisionGeom:CollisionGeometry;	// for detecting collision on this mesh geometry
		private var illuminable:Boolean = true;			// specifies if this mesh can be illuminated with directional lights
		private var material:Material;					// contains {ambR,ambG,ambB,specStr,specHard,fogR,fogG,fogB,fogFar}

		public var trisCnt:int;							// number of triangles to tell program to draw
		private var texture:BitmapData;					// texture of current mesh, can be null
		private var normMap:BitmapData;					// combined normal map of current mesh, can be null
		private var specMap:BitmapData;					// combined speclar map of current mesh, can be null
		private var vertexBuffer:VertexBuffer3D;		// Where Vertex positions for this mesh will be stored
		private var indexBuffer:IndexBuffer3D;			// Order of Vertices to be drawn for this mesh
		private var textureBuffer:Texture;				// uploaded Texture of this mesh
		private var normMapBuffer:Texture;				// uploaded normal map of this mesh
		private var specMapBuffer:Texture;				// uploaded specular map of this mesh
		private var envMapBuffer:CubeTexture;			// uploaded env map of this mesh
		private var stdProgram:Program3D;				// rendering program specific for this mesh
		private var depthProgram:Program3D;				// program for rendering depth maps for shadow mapping

		public var depthWrite:Boolean=true;				// whether to write to depth buffer
		private var blendSrc:String="one";				// source pixel blend mode
		private var blendDest:String="zero";			// destination pixel blend mode

		private var dataType:int = -1;					// empty mesh type is -1
		private var builtOnState:uint = 0;				// must match global stateId for shader program to be guaranteed valid

		public static const _typeV:int = 0;				// normal vertices data
		public static const _typeS:int = 1;				// skinning data
		public static const _typeP:int = 2;				// batch particles data
		public static const _typeM:int = 3;				// batch meshes data

		public static var focalL:Number = 1;			// GLOBAL camera focal length
		public static var nearClip:Number = 1;			// GLOBAL near clipping plane during rendering
		public static var farClip:Number = 1000;		// GLOBAL far clipping plane during rendering
		public static var viewT:Matrix4x4=null;			// GLOBAL scene transform matrix
		public static var camT:Matrix4x4=null;			// GLOBAL camera view transform matrix
		public static var lightsConst:Vector.<Number>;	// GLOBAL [vx,vy,vz,1,r,g,b,1, vx,vy,vz,1,r,g,b,1, ...] point light values
		public static var debugTf:TextField = null;

		private static var outTex:Texture;				// GLOBAL for post processing filters support

		private static var antiAliasing:uint = 4;		// render result antialiasing
		private static var viewWidth:uint = 800;		// current width of render viewport
		private static var viewHeight:uint = 600; 		// current height of render viewport
		public static var context3d:Context3D;			// reference to the shared context3D for rendering onto stage3D

		// ----- remembers previous assets used in render to skip resetting buffers
		private static var prevType:int = -1;
		private static var prevTex:Texture=null;
		private static var prevEnv:CubeTexture=null;
		private static var prevNorm:Texture=null;
		private static var prevSpec:Texture=null;
		private static var prevProg:Program3D = null;
		private static var renderedWithShadows:Boolean=false;
		private static var stateId:uint = 1;			// incremented when global settings changed


		private static var gettingContext:Boolean = false;	// GLOBAL chks if in process of getting context
		private static var lightDCMs:Vector.<CubeTexture>;	// GLOBAL depth buffers rendered light POV used for shadow mapping
		private static var uploadedTextures:Array;			// GLOBAL list of uploaded textures [bmd,textureBuffer,bmd,textureBuffer ... ]
		private static var uploadedPrograms:Array;			// GLOBAL list of upload programs [string,program,string,program ... ]

		private static var numMeshes:int = 0;			// for stats tracking while rendering
		private static var drawCalls:int = 0;			// for stats tracking while rendering
		private static var trisRendered:int = 0;		// for stats tracking while rendering
		private static var fTV:Vector.<int>=null;		// for stats tracking time of each render call
		public static var fpsStats:String="";			// stats traceout of the last render

		/**
		* create an empty mesh
		*/
		public function Mesh() : void
		{
			childMeshes = new Vector.<Mesh>();	// child meshes list
			transform = new Matrix4x4();
			material = new Material();
			setAmbient(0.3, 0.3, 0.3);			// R,G,B
			setSpecular(0,5);					// strength,hardness
			setFog();
		}//endconstructor

		/**
		* does a clone of this entire branch (deep clone) and returns clone
		*/
		public function clone() : Mesh
		{
			if (vertData!=null && vertData.length>0 && vertexBuffer==null && context3d!=null)
				setContext3DBuffers(renderedWithShadows);	// if buffers not set

			var m:Mesh = new Mesh();
			m.dataType = dataType;
			m.trisCnt = trisCnt;
			m.vertData = vertData;
			m.idxsData = idxsData;
			m.jointsData = jointsData;
			m.collisionGeom = collisionGeom;	// pass collision geometry over!
			m.texture = texture;
			m.normMap = normMap;
			m.specMap = specMap;
			m.material = material.clone();
			m.vertexBuffer = vertexBuffer;
			m.indexBuffer = indexBuffer;
			m.textureBuffer = textureBuffer;
			m.normMapBuffer = normMapBuffer;
			m.envMapBuffer = envMapBuffer;
			m.stdProgram = stdProgram;
			m.depthProgram = depthProgram;
			m.illuminable = illuminable;
			m.builtOnState = builtOnState;
			m.transform = transform.scale(1,1,1);

			for (var i:int=0; i<childMeshes.length; i++)
				m.addChild(childMeshes[i].clone());

			return m;
		}//endfunction

		/**
		* returns mesh with laterally inverted geometry
		*/
		public function mirrorX() : Mesh
		{
			var m:Mesh = this.clone();
			_mirrorTree(m);
			return m;
		}//endfunction

		/**
		* laterally inverts the geometry of given mesh tree
		*/
		private static function _mirrorTree(m:Mesh) : void
		{
			if (m.dataType==_typeV)
			{
				m.indexBuffer = null;	// force buffers re upload
				m.vertexBuffer = null;	// force buffers re upload

				var n:uint=0;
				var j:int=0;
				if (m.idxsData!=null)
				{
					m.idxsData = m.idxsData.slice();
					n = m.idxsData.length;
					for (j=0; j<n; j+=3)
					{	// swap triangle facing
						var tmp:uint = m.idxsData[j+1];
						m.idxsData[j+1] = m.idxsData[j+2];
						m.idxsData[j+2] = tmp;
					}
				}
				if (m.vertData!=null)
				{
					m.vertData = m.vertData.slice();
					n = m.vertData.length;
					for (j=0; j<n; j+=11)
					{	// invert x value
						m.vertData[j]*=-1;
						m.vertData[j+3]*=-1;
						m.vertData[j+6]*=-1;
					}
				}
			}

			if (m.transform!=null) m.transform.ad*=-1;
			for (var i:int=m.childMeshes.length-1; i>-1; i--)
				_mirrorTree(m.childMeshes[i]);
		}//endfunction

		/**
		* returns new mesh with geometry of current node and all its child nodes MERGED together
		*/
		public function mergeTree() : Mesh
		{
			if (childMeshes.length==0) return clone();

			var nV:Vector.<Number> = null;
			var nI:Vector.<uint> = null;
			var idxOff:uint = 0;

			if (dataType!=_typeV || vertData==null)
			{
				nV = new Vector.<Number>();
				nI = new Vector.<uint>();
			}
			else
			{
				nV = vertData.slice();
				nI = idxsData.slice();
				idxOff = nV.length/11;
			}

			var tex:BitmapData = this.texture;
			var norm:BitmapData = this.normMap;
			var spec:BitmapData = this.specMap;
			for (var i:int=childMeshes.length-1; i>-1; i--)
			{
				var c:Mesh = childMeshes[i].mergeTree();
				if (tex==null)	tex = c.texture;
				if (norm==null)	norm = c.normMap;
				if (spec==null)	spec = c.specMap;
				var cT:Matrix4x4 = c.transform;
				var vD:Vector.<Number> = c.vertData;
				var iD:Vector.<uint> = c.idxsData;
				if (vD!=null && iD!=null)
				{
					var n:int = vD.length;
					for (var j:int=0; j<n;)
					{
						var vx:Number = vD[j++];
						var vy:Number = vD[j++];
						var vz:Number = vD[j++];
						var nx:Number = vD[j++];
						var ny:Number = vD[j++];
						var nz:Number = vD[j++];
						var tx:Number = vD[j++];
						var ty:Number = vD[j++];
						var tz:Number = vD[j++];
						var nvx:Number = cT.aa*vx+cT.ab*vy+cT.ac*vz+cT.ad;
						var nvy:Number = cT.ba*vx+cT.bb*vy+cT.bc*vz+cT.bd;
						var nvz:Number = cT.ca*vx+cT.cb*vy+cT.cc*vz+cT.cd;
						var nnx:Number = cT.aa*nx+cT.ab*ny+cT.ac*nz;
						var nny:Number = cT.ba*nx+cT.bb*ny+cT.bc*nz;
						var nnz:Number = cT.ca*nx+cT.cb*ny+cT.cc*nz;
						var ntx:Number = cT.aa*tx+cT.ab*ty+cT.ac*tz;
						var nty:Number = cT.ba*tx+cT.bb*ty+cT.bc*tz;
						var ntz:Number = cT.ca*tx+cT.cb*ty+cT.cc*tz;
						//var nnl:Number = Math.sqrt(nnx*nnx+nny*nny+nnz*nnz);
						//nnx/=nnl; nny/=nnl; nnz/=nnl;
						nV.push(nvx,nvy,nvz,nnx,nny,nnz,ntx,nty,ntz,vD[j++],vD[j++]);
					}//endfor

					n = iD.length;
					for (j=0; j<n; j++)	nI.push(iD[j]+idxOff);

					idxOff+=vD.length/11;
				}//endif

			}//endfor

			var m:Mesh = new Mesh();
			m.illuminable = illuminable;
			m.material = material.clone();
			m.transform = transform;
			m.setGeometry(nV,nI);
			m.texture = tex;
			m.normMap = norm;
			m.specMap = spec;
			return m;
		}//endfunction

		/**
		* adds given mesh as child mesh of this mesh
		*/
		public function addChild(m:Mesh) : Boolean
		{
			if (m==null || this.containsChild(m))	return false;
			childMeshes.push(m);
			return true;
		}//endfunction

		/**
		* removes given mesh from this mesh/tree returns parent mesh
		*/
		public function removeChild(msh:Mesh) : Mesh
		{
			if (msh==this)	return null;	// cannot remove self

			// ----- define removal function
			var parentM:Mesh=null;
			var i:int=childMeshes.length-1;
			while (parentM==null && i>=0)
			{
				if (childMeshes[i]==msh)
				{
					parentM=this;
					childMeshes.splice(i,1);
				}
				else
				{
					var pm:Mesh=childMeshes[i].removeChild(msh);
					if (pm!=null) parentM=pm;
				}
				i--;
			}//endwhile

			return parentM;	// abort ==true if msh removed
		}//endfunction

		/**
		* function to check if mesh is already a subchild of this
		*/
		public function containsChild(msh:Mesh) : Boolean
		{
			if (msh==this)	return false;	// cannot contain self

			var contain:Boolean = false;		// whether to continue
			var i:int=childMeshes.length-1;
			while (contain==false && i>-1)
			{
				if (childMeshes[i]==msh)
					contain=true;
				else
					childMeshes[i].containsChild(msh);
				i--;
			}//endwhile

			return contain;
		}//endfunction

		/**
		* function to return ith child of this mesh
		*/
		public function getChildAt(i:uint) :Mesh
		{
			if (i>childMeshes.length)	return null;
			return childMeshes[i];
		}//endfunction

		/**
		* return number of child meshes of this mesh
		*/
		public function numChildren() : uint
		{
			return childMeshes.length;
		}//endfunction

		/**
		* removes all submeshes attached to this
		*/
		public function removeAllChildren() : void
		{
			while (childMeshes.length>0)
				childMeshes.pop();
		}//endfunction

		/**
		* enables/disables directional and specular lighting effects for this mesh
		*/
		public function enableLighting(enable:Boolean,propagate:Boolean=false) : void
		{
			illuminable=enable;
			stdProgram=null;

			if (propagate)
			for (var i:int=childMeshes.length-1; i>-1; i--)
				childMeshes[i].enableLighting(enable,propagate);
		}//endfunction

		/**
		* convenience function to get total vertices data
		*/
		public function getVertLen(): uint
		{
			var cnt:uint=0;
			if (vertData!=null)	cnt = vertData.length;
			for (var i:int=childMeshes.length-1; i>=0; i--)
				cnt+=childMeshes[i].getVertLen();
			return cnt;
		}//endfunction

		/**
		* brute force check to reduce the number of vertices uploaded by reusing identical vertices
		* returns new mesh
		*/
		public function compressGeometry(propagate:Boolean=false) : void
		{
			if (dataType!=_typeV) return;

			var timr:uint = getTimer();

			var oV:Vector.<Number> = vertData;
			var oI:Vector.<uint> = idxsData;

			if (oV!=null && oI!=null)
			{
				var tV:Vector.<VertexData> = new Vector.<VertexData>();
				var nI:Vector.<uint> = new Vector.<uint>();

				var n:uint = 0;				// tracks length of tV
				var l:uint = oI.length;
				for (var i:int=0; i<l; i++)
				{
					var oidx:uint = oI[i]*11;		// old index
					var vx:Number = oV[oidx++];
					var vy:Number = oV[oidx++];
					var vz:Number = oV[oidx++];
					var nx:Number = oV[oidx++];
					var ny:Number = oV[oidx++];
					var nz:Number = oV[oidx++];
					var tx:Number = oV[oidx++];
					var ty:Number = oV[oidx++];
					var tz:Number = oV[oidx++];
					var u:Number = oV[oidx++];
					var v:Number = oV[oidx++];

					var nidx:int = -1;			// new index
					n = tV.length;
					for (var j:int=0; j<n && nidx==-1; j++)
					{
						var vd:VertexData = tV[j];
						if (vd.vx==vx && vd.vy==vy && vd.vz==vz &&
							vd.nx==nx && vd.ny==ny && vd.nz==nz &&
							vd.u==u && vd.v==v)
							nidx = j;
					}

					if (nidx==-1)
					{
						nidx = n;
						tV.push(new VertexData(vx,vy,vz,nx,ny,nz,u,v,0,0,tx,ty,tz));
					}
					nI.push(nidx);
				}//endfor

				var nV:Vector.<Number> = new Vector.<Number>();
				n = tV.length;
				for (i=0; i<n; i++)
				{
					vd = tV[i];
					nV.push(vd.vx,vd.vy,vd.vz,vd.nx,vd.ny,vd.nz,vd.tx,vd.ty,vd.tz,vd.u,vd.v);
				}

				setGeometry(nV,nI);
				debugTrace("compressed T:"+(getTimer()-timr)+" from "+oV.length/11+" to "+nV.length/11+"");
			}

			// ----- do for submeshes too if required
			if (propagate)
			for (i=0; i<childMeshes.length; i++)
				childMeshes[i].compressGeometry(propagate);
		}//endfunction

		/**
		 * calculate normals if non exist, calculate tangents and calls setGeometry
		 * verticesData : [vx,vy,vz,nx,ny,nz,u,v, ...]
		 * indicesData : [idx1,idx2,idx3, idx1,idx2,idx3, ...]
		 */
		public function createGeometry(verticesData:Vector.<Number>=null,indicesData:Vector.<uint>=null) : void
		{
			if (verticesData==null) verticesData = new Vector.<Number>();

			// ----- trim down vertices if too much ---------------------------
			var maxVertices:uint = 65535;
			if (verticesData.length>maxVertices*8)
			{
				debugTrace("trimming numvertices down to "+maxVertices);
				verticesData = verticesData.slice(0,maxVertices*8);
			}
			var n:Number = verticesData.length/8;

			// ----- generate indices data for triangles if null --------------
			if (indicesData == null)
			{
				indicesData=new Vector.<uint>();
				for (i=0; i<n; i++)	indicesData.push(i);
			}

			// ----- calc default normals to data if normals are 0,0,0 --------
			for (var i:int=0; i<n; i+=3)		// 1 tri takes 24 numbers data
			{
				var ia:int = indicesData[i] * 8;
				var ib:int = indicesData[i+1] * 8;
				var ic:int = indicesData[i+2] * 8;

				if ((verticesData[3+ia]==0 && verticesData[4+ia]==0 && verticesData[5+ia]==0) ||
					(verticesData[3+ib]==0 && verticesData[4+ib]==0 && verticesData[5+ib]==0) ||
					(verticesData[3+ic]==0 && verticesData[4+ic]==0 && verticesData[5+ic]==0))
				{
					// ----- get vertices -------------------------------------
					var vax:Number = verticesData[0+ia];
					var vay:Number = verticesData[1+ia];
					var vaz:Number = verticesData[2+ia];
					var vbx:Number = verticesData[0+ib];
					var vby:Number = verticesData[1+ib];
					var vbz:Number = verticesData[2+ib];
					var vcx:Number = verticesData[0+ic];
					var vcy:Number = verticesData[1+ic];
					var vcz:Number = verticesData[2+ic];

					// ----- calculate default normals ------------------------
					var px:Number = vbx - vax;
					var py:Number = vby - vay;
					var pz:Number = vbz - vaz;
					var qx:Number = vcx - vax;
					var qy:Number = vcy - vay;
					var qz:Number = vcz - vaz;
					// normal by determinant
					var nx:Number = py*qz-pz*qy;	//	unit normal x for the triangle
					var ny:Number = pz*qx-px*qz;	//	unit normal y for the triangle
					var nz:Number = px*qy-py*qx;	//	unit normal z for the triangle
					var nl:Number = Math.sqrt(nx*nx+ny*ny+nz*nz);
					nx/=nl; ny/=nl; nz/=nl;
					verticesData[3+ia]=nx; verticesData[4+ia]=ny; verticesData[5+ia]=nz;
					verticesData[3+ib]=nx; verticesData[4+ib]=ny; verticesData[5+ib]=nz;
					verticesData[3+ic]=nx; verticesData[4+ic]=ny; verticesData[5+ic]=nz;
				}//endif
			}//endfor

			// ----- genertates tangents and sets geometry data to mesh -------
			setGeometry(calcTangentBasis(indicesData,verticesData),indicesData);
			compressGeometry();
		}//endfunction

		/**
		* gives/overrides new geometry and triangle indices to this mesh
		* verticesData : [vx,vy,vz,nx,ny,nz,tx,ty,tz,u,v, ...]
		* indicesData : [idx1,idx2,idx3, idx1,idx2,idx3, ...]
		* overwrite : replace last data, even for cloned meshes
		*/
		public function setGeometry(verticesData:Vector.<Number>=null,indicesData:Vector.<uint>=null,overwrite:Boolean=false) : void
		{
			//debugTrace("setGeometry vertData:"+vertData.length+"  idxsData:"+idxsData.length+" ");

			vertData = verticesData;
			idxsData = indicesData;

			// dont dispose buffers because cloned meshes share the same buffers
			if (!overwrite && vertexBuffer!=null) /*vertexBuffer.dispose();*/	vertexBuffer=null;
			if (!overwrite && indexBuffer!=null) /*indexBuffer.dispose();*/	indexBuffer=null;

			var numVertices:int = vertData.length/11;
			trisCnt = idxsData.length/3;		// sets number of triangles to render

			if (idxsData.length<3)
			{
				vertData=null; idxsData=null; dataType=-1; return;		// null dataset!!
			}

			dataType = _typeV;

			// ----- derive collision geometry ----------------------------------------
			if (collisionGeom==null || !overwrite) collisionGeom = new CollisionGeometry(vertData,idxsData);

			if (context3d==null)	return;

			// ----- set context vertices data ----------------------------------------
			if (!overwrite || vertexBuffer==null) 	vertexBuffer=context3d.createVertexBuffer(numVertices, 11);	// vx,vy,vz,nx,ny,nz,tx,ty,tz,u,v
			vertexBuffer.uploadFromVector(vertData, 0, numVertices);

			// ----- set context indices data -----------------------------------------
			if (!overwrite || indexBuffer==null)
				indexBuffer=context3d.createIndexBuffer(idxsData.length);
			indexBuffer.uploadFromVector(idxsData,0,idxsData.length);
		}//endfunction

		/**
		* sets batch rendered particles data and indices to this mesh
		* particlesData : [vx,vy,vz, u,v,idx,...]	point position, uv, vc translation idx
		*/
		public function setParticles(particlesData:Vector.<Number>=null,indicesData:Vector.<uint>=null) : void
		{
			vertData = particlesData;
			idxsData = indicesData;
			// dont dispose buffers because cloned meshes share the same buffers
			if (vertexBuffer!=null) /*vertexBuffer.dispose();*/	vertexBuffer=null;
			if (indexBuffer!=null) /*indexBuffer.dispose();*/	indexBuffer=null;
			dataType = _typeP;
			depthWrite = false;

			if (vertData==null || idxsData==null) return;

			var numVertices:int = vertData.length/6;
			trisCnt = idxsData.length/3;		//sets number of triangles to render

			if (numVertices==0 || trisCnt==0) {vertData=null; idxsData=null; return;}

			if (context3d==null)	return;

			// ----- set context vertices data ----------------------------------------
			vertexBuffer=context3d.createVertexBuffer(numVertices, 6);	// vertex vx,vy,vz, u,v, idx
			vertexBuffer.uploadFromVector(vertData, 0, numVertices);

			// ----- set context indices data -----------------------------------------
			indexBuffer=context3d.createIndexBuffer(idxsData.length);
			indexBuffer.uploadFromVector(idxsData, 0, idxsData.length);
		}//endfunction

		/**
		* sets batch rendered mesh copies data and indices to this mesh
		* meshesData : [x,y,z, nx,ny,nz, tx,ty,tz, u,v, idx,idx+1]	point position, normal, uv, vc orientation and translation idx
		*/
		public function setMeshes(meshesData:Vector.<Number>=null,indicesData:Vector.<uint>=null) : void
		{
			vertData = meshesData;
			idxsData = indicesData;
			// dont dispose buffers because cloned meshes share the same buffers
			if (vertexBuffer!=null) /*vertexBuffer.dispose();*/	vertexBuffer=null;
			if (indexBuffer!=null) /*indexBuffer.dispose();*/	indexBuffer=null;
			dataType = _typeM;

			if (vertData==null || idxsData==null) return;

			var numVertices:int = vertData.length/13;
			trisCnt = idxsData.length/3;		//sets number of triangles to render

			if (numVertices==0 || trisCnt==0) {vertData=null; idxsData=null; return;}

			if (context3d==null)	return;

			// ----- set context vertices data ----------------------------------------
			vertexBuffer=context3d.createVertexBuffer(numVertices, 13);	// vertex x,y,z, nx,ny,nz, tx,ty,tz, u,v,idx,idx+1
			vertexBuffer.uploadFromVector(vertData, 0, numVertices);

			// ----- set context indices data -----------------------------------------
			indexBuffer=context3d.createIndexBuffer(idxsData.length);
			indexBuffer.uploadFromVector(idxsData, 0, idxsData.length);
		}//endfunction

		/**
		* skinningData : [	va0 = texU,texV	 					// UV for this point
		*					va1 = wnx,wny,wnz,transIdx 			// weight normal 1
		* 					va2 = wtx,wty,wtz,transIdx 			// weight tangent 1
		*					va3 = wvx,wvy,wvz,transIdx+weight 	// weight vertex 1
		*					va4 = wvx,wvy,wvz,transIdx+weight  	// weight vertex 2
		*					va5 = wvx,wvy,wvz,transIdx+weight  	// weight vertex 3
		*					va6 = wvx,wvy,wvz,transIdx+weight ]	// weight vertex 4...
		*/
		public function setSkinning(skinningData:Vector.<Number>=null,indicesData:Vector.<uint>=null) : void
		{
			vertData = skinningData;
			idxsData = indicesData;
			// dont dispose buffers because cloned meshes share the same buffers
			if (vertexBuffer!=null) /*vertexBuffer.dispose();*/	vertexBuffer=null;
			if (indexBuffer!=null) /*indexBuffer.dispose();*/	indexBuffer=null;
			dataType = _typeS;

			if (skinningData==null || indicesData==null) return;

			var numVertices:int = vertData.length/26;
			trisCnt = idxsData.length/3;		//sets number of triangles to render

			if (numVertices==0 || trisCnt==0) {vertData=null; idxsData=null; return;}

			if (context3d==null)	return;

			// ----- set context vertices data ----------------------------------------
			vertexBuffer=context3d.createVertexBuffer(numVertices, 26);
			vertexBuffer.uploadFromVector(vertData, 0, numVertices);

			// ----- set context indices data -----------------------------------------
			indexBuffer=context3d.createIndexBuffer(idxsData.length);
			indexBuffer.uploadFromVector(idxsData,0,idxsData.length);
		}//endfunction

		/**
		* returns the datatype for this mesh
		*/
		public function getDataType() : uint
		{
			return dataType;
		}//endfunction

		/**
		* sets/overrides new texture to this mesh
		*/
		public function setTexture(bmd:BitmapData,propagate:Boolean=false,update:Boolean=false) : void
		{
			if ((texture==null && bmd!=null) || (texture!=null && bmd==null))
			{
				stdProgram=null;
			}
			texture = powOf2Size(bmd);
			textureBuffer = uploadTextureBuffer(texture,update,true);
			if (blendSrc=="sourceAlpha" && blendDest=="one") {}
			else if (texture!=null && texture.transparent)	setBlendMode("alpha");
			else											setBlendMode("normal");

			if (propagate)
			for (var i:int=childMeshes.length-1; i>-1; i--)
				childMeshes[i].setTexture(bmd,propagate,update);
		}//endfunction

		/**
		* sets/overrides new normal map to this mesh
		*/
		public function setNormalMap(bmd:BitmapData,propagate:Boolean=false,update:Boolean=false) : void
		{
			if ((normMap==null && bmd!=null) || (normMap!=null && bmd==null))
			{
				stdProgram=null;
			}
			normMap = powOf2Size(bmd);
			normMapBuffer = uploadTextureBuffer(normMap,update,true);

			if (propagate)
			for (var i:int=childMeshes.length-1; i>-1; i--)
				childMeshes[i].setNormalMap(bmd,propagate,update);
		}//endfunction

		/**
		* sets/overrides new specular map to this mesh
		*/
		public function setSpecularMap(bmd:BitmapData,propagate:Boolean=false,update:Boolean=false) : void
		{
			if ((specMap==null && bmd!=null) || (specMap!=null && bmd==null))
			{
				stdProgram=null;
			}
			specMap = powOf2Size(bmd);
			specMapBuffer = uploadTextureBuffer(specMap,update,true);

			if (propagate)
			for (var i:int=childMeshes.length-1; i>-1; i--)
				childMeshes[i].setSpecularMap(bmd,propagate,update);
		}//endfunction

		/**
		* sets up the environment map for this mesh... so it is reflecting mirror like
		*/
		public function createEnvMap(stage:Stage,world:Mesh,size:int=512) : CubeTexture
		{
			if (context3d==null) return null;

			var eM:CubeTexture=envMapBuffer;
			if (eM==null) eM=context3d.createCubeTexture(size,"bgra",true);
			var parentM:Mesh = world.removeChild(this);		// exclude from render!
			renderEnvCubeTex(stage,world,eM,transform.ad,transform.bd,transform.cd);
			if (parentM!=null) parentM.addChild(this);
			return eM;
		}//endfunction

		/**
		* sets up the environment map for this mesh... so it is reflecting mirror like
		*/
		public function setEnvMap(eM:CubeTexture,propagate:Boolean=false) : void
		{
			if (envMapBuffer==null)
			{
				stdProgram=null;
			}
			envMapBuffer = eM;

			for (var i:int=childMeshes.length-1; i>-1; i--)
				childMeshes[i].setEnvMap(eM,propagate);
		}//endfunction

		/**
		* clears off environment map for this mesh...
		*/
		public function clearEnvMap(propagate:Boolean=false) : void
		{
			if (envMapBuffer!=null)
			{
				stdProgram=null;
			}
			envMapBuffer = null;

			if (propagate)
			for (var i:int=childMeshes.length-1; i>-1; i--)
				childMeshes[i].clearEnvMap(propagate);
		}//endfunction

		/**
		* returns existing Texture for given bmd, else creates and returns a new Texture, if bmd==null return null
		*/
		private static function uploadTextureBuffer(bmd:BitmapData,update:Boolean=false,mip:Boolean=false,optimizeForRender:Boolean=false) : Texture
		{
			if (context3d==null) return null;
			var buff:Texture = null;

			// ----- setup uploaded textures list ----------------------------
			if (uploadedTextures==null)	uploadedTextures=[];

			// ----- return the relevant uploaded texture --------------------
			if (bmd==null)
				return null;	// no bitmap texture, render as default grey shaded
			else if (uploadedTextures.indexOf(bmd)!=-1)
			{
				//debugTrace("reusing uploaded texture at "+(uploadedTextures.indexOf(bmd)+1)+"");
				buff = uploadedTextures[uploadedTextures.indexOf(bmd)+1];
				if (update) buff.uploadFromBitmapData(bmd);
				return buff;	// return corresponding texture
			}
			else
			{
				buff = context3d.createTexture(bmd.width,bmd.height,Context3DTextureFormat.BGRA, optimizeForRender);
				uploadedTextures.push(bmd,buff);
				debugTrace("uploading new Texture w:"+bmd.width+"h:"+bmd.height+" , total="+uploadedTextures.length/2);
				if (mip)
				{
					buff.uploadFromBitmapData(bmd,0);	// upload original tex
					var mipLv:int=0;
					var sc:Number = 1;
					while (bmd.width*sc>1 && bmd.height*sc>1)
					{	// calculate and upload mip levels
						mipLv++;
						sc = 1/Math.pow(2,mipLv);
						var mbmd:BitmapData = new BitmapData(bmd.width*sc,bmd.height*sc,bmd.transparent,0);
						mbmd.draw(bmd,new Matrix(sc,0,0,sc));
						buff.uploadFromBitmapData(mbmd,mipLv);
						mbmd.dispose();
					}
				}
				else
					buff.uploadFromBitmapData(bmd);
				return buff;	// return newly created texture
			}
		}//endfunction

		/**
		* sets the ambient parameters for this mesh only, if propagate, child meshes too
		*/
		public function setAmbient(red:Number=0.5,green:Number=0.5,blue:Number=0.5,propagate:Boolean=false) : void
		{
			if ((material.ambR==1 && material.ambG==1 && material.ambB==1) ||
				(red==1 && green==1 && blue==1))
			{
				stdProgram=null;
			}
			material.ambR = red;
			material.ambG = green;
			material.ambB = blue;

			if (propagate)
			for (var i:int=childMeshes.length-1; i>-1; i--)
				childMeshes[i].setAmbient(red,green,blue,propagate);
		}//endfunction

		/**
		 * sets the specular parameters for this mesh only, if propagate, child meshes too
		 */
		public function setSpecular(strength:Number=0.5,hardness:uint=5,propagate:Boolean=false) : void
		{
			if ((material.specStr==0) || strength==0)
			{
				stdProgram=null;
			}
			material.specStr = strength;
			material.specHard = hardness;

			if (propagate)
			for (var i:int=childMeshes.length-1; i>-1; i--)
				childMeshes[i].setSpecular(strength,hardness,propagate);
		}//endfunction

		/**
		* sets the linear fog parameters for this mesh, fogDist is dist where objects are totally covered by fog, if propagate, child meshes too
		*/
		public function setFog(red:Number=0.5,green:Number=0.5,blue:Number=0.5,fogDist:Number=0,propagate:Boolean=false) : void
		{
			if (fogDist!=material.fogFar)
			{
				stdProgram=null;
			}
			material.fogR = red;
			material.fogG = green;
			material.fogB = blue;
			material.fogFar = fogDist;

			if (propagate)
			for (var i:int=childMeshes.length-1; i>-1; i--)
				childMeshes[i].setFog(red,green,blue,fogDist,propagate);
		}//endfunction

		/**
		* blending when drawing to stage, one of "add", "alpha", "normal"
		*/
		public function setBlendMode(s:String,propagate:Boolean=false) : void
		{
			s = s.toLowerCase();
			if (s=="add")		{blendSrc="sourceAlpha"; blendDest="one";}
			if (s=="alpha")		{blendSrc="sourceAlpha"; blendDest="oneMinusSourceAlpha";}
			if (s=="normal")	{blendSrc="one"; blendDest="zero";}

			if (propagate)
			for (var i:int=childMeshes.length-1; i>-1; i--)
				childMeshes[i].setBlendMode(s,propagate);
		}//endfunction

		/**
		* refreshes/sets data buffers and build and upload rendering programs of this mesh
		*/
		private function setContext3DBuffers(shadows:Boolean) : void
		{
			if (context3d==null)	return;

			// ----- upload geometry data ---------------------------
			if (vertexBuffer==null || indexBuffer==null)
			{
				if (dataType==_typeV)		setGeometry(vertData,idxsData);
				else if (dataType==_typeP)	setParticles(vertData,idxsData);
				else if (dataType==_typeM)	setMeshes(vertData,idxsData);
				else if (dataType==_typeS)	setSkinning(vertData,idxsData);
			}

			// ----- upload texture and specmap ---------------------
			textureBuffer = uploadTextureBuffer(texture,false,true);	// no update upload mips
			normMapBuffer = uploadTextureBuffer(normMap,false,true);	// no update upload mips
			specMapBuffer = uploadTextureBuffer(specMap,false,true);	// no update upload mips

			// ----- create mesh custom shader program --------------
			if (lightsConst==null)	lightsConst = Vector.<Number>();
			var numLights:uint = lightsConst.length/8;
			if (dataType==_typeP)	illuminable=false;	// no lighting for particles
			if (illuminable==false)	numLights=0;

			var vertSrc:String = _stdPersVertSrc(numLights>0,material.fogFar>0,normMap!=null);
			if (dataType==_typeV)		vertSrc = _stdReadVertSrc(numLights>0,normMap!=null) + vertSrc;
			else if (dataType==_typeP)	vertSrc = _particlesVertSrc() + vertSrc;
			else if (dataType==_typeM)	vertSrc = _meshesVertSrc(numLights>0,normMap!=null) + vertSrc;
			else if (dataType==_typeS)	vertSrc = _skinningVertSrc(numLights>0) + vertSrc;

			var fragSrc:String = null;
			if (texture!=null && numLights==0 && material.ambR==1 && material.ambG==1 && material.ambB==1 && material.specStr==0 && material.fogFar==0)
				fragSrc = "tex oc, v2, fs0 <2d,linear,mipnone,repeat>\n";
			else
				fragSrc = _stdFragSrc(numLights,texture!=null,useMipMapping,normMap!=null,specMap!=null,material.fogFar>0,envMapBuffer!=null,shadows);

			stdProgram = createProgram(vertSrc,fragSrc);
			builtOnState = stateId;

			// ----- create depth texture render program ------------
			vertSrc = _depthCubePersVertSrc();	// common vert shader code
			if (dataType==_typeV)		vertSrc = "mov vt0, va0\n" + vertSrc;
			else if (dataType==_typeP)	vertSrc = _particlesVertSrc() + vertSrc;
			else if (dataType==_typeM)	vertSrc = _meshesVertSrc(false,false) + vertSrc;
			else if (dataType==_typeS)	vertSrc = _skinningVertSrc(false) + vertSrc;
			depthProgram = createProgram(vertSrc, _depthCubeFragSrc());

			//debugTrace("setContext3DBuffers");
		}//endfunction

		/**
		* given vertex and fragment sources create upload and returns a shader program
		*/
		private static function createProgram(agalVertexSource:String,agalFragmentSource:String) : Program3D
		{
			// ----- chk for already cached program for reuse
			var idstr:String = agalVertexSource+"\n\n"+agalFragmentSource;
			if (uploadedPrograms==null)	uploadedPrograms=[];
			var idx:int=uploadedPrograms.indexOf(idstr);
			if (idx!=-1) return uploadedPrograms[idx+1];	// returns previously compiled program

			// ----- build new program if no cached program is found
			var prog:Program3D = null;
			try {
			var agalVertex:AGALMiniAssembler=new AGALMiniAssembler();
			var agalFragment:AGALMiniAssembler=new AGALMiniAssembler();
			agalVertex.assemble("vertex", agalVertexSource);
			agalFragment.assemble("fragment", agalFragmentSource);
			prog = context3d.createProgram();
			prog.upload(agalVertex.agalcode, agalFragment.agalcode);
			} catch (e:Error) {debugTrace("AGAL compile error "+e);}

			// ----- cache program for future reuse, upload is expensive
			uploadedPrograms.push(idstr,prog);

			return prog;
		}//endfunction

		/**
		* to return as a flattened list the children and grandchildrens of this mesh, self included
		*/
		private function flattenTree(T:Matrix4x4,conV:Vector.<Mesh>):void
		{
			if (transform==null) transform = new Matrix4x4();
			workingTransform = T.mult(transform);	// working transform of this mesh
			conV.push(this);
			for (var i:int=childMeshes.length-1; i>-1; i--)
				childMeshes[i].flattenTree(workingTransform,conV);
		}//endfunction

		/**
		* given line start posn (lox,loy,loz) and line vector (lvx,lvy,lvz)
		* returns {vx,vy,vz,nx,ny,nz} the 3D position and surface normal where line hits this mesh (optionally after applying transform T), or null
		*/
		public function lineHitsMesh(lox:Number,loy:Number,loz:Number,lvx:Number,lvy:Number,lvz:Number,T:Matrix4x4=null) : VertexData
		{
			if (transform==null) 	transform = new Matrix4x4();
			if (T==null)	T = transform;
			else			T = T.mult(transform);	// concat transform with self transform

			var hpt:VertexData = null;
			if (collisionGeom!=null)
			{
				// ----- inverse transform line to object space ---------
				var invT:Matrix4x4 = T.inverse();
				var ox:Number = invT.aa*lox + invT.ab*loy + invT.ac*loz + invT.ad;	// transform point
				var oy:Number = invT.ba*lox + invT.bb*loy + invT.bc*loz + invT.bd;
				var oz:Number = invT.ca*lox + invT.cb*loy + invT.cc*loz + invT.cd;
				var vx:Number = invT.aa*lvx + invT.ab*lvy + invT.ac*lvz;			// rotate line vector
				var vy:Number = invT.ba*lvx + invT.bb*lvy + invT.bc*lvz;
				var vz:Number = invT.ca*lvx + invT.cb*lvy + invT.cc*lvz;

				if (collisionGeom.lineHitsBounds(ox,oy,oz,vx,vy,vz))
					hpt = collisionGeom.lineHitsGeometry(ox,oy,oz,vx,vy,vz);

				if (hpt!=null)
				{
					// ----- transform hit pt to global space ---------------
					ox = T.aa*hpt.vx + T.ab*hpt.vy + T.ac*hpt.vz + T.ad;	// un transform hit point
					oy = T.ba*hpt.vx + T.bb*hpt.vy + T.bc*hpt.vz + T.bd;
					oz = T.ca*hpt.vx + T.cb*hpt.vy + T.cc*hpt.vz + T.cd;
					vx = T.aa*hpt.nx + T.ab*hpt.ny + T.ac*hpt.nz;			// un rotate hit normal
					vy = T.ba*hpt.nx + T.bb*hpt.ny + T.bc*hpt.nz;
					vz = T.ca*hpt.nx + T.cb*hpt.ny + T.cc*hpt.nz;
					var vl:Number = 1/Math.sqrt(vx*vx+vy*vy+vz*vz);
					vx*=vl;	vy*=vl; vz*=vl;
					hpt = new VertexData(ox,oy,oz,vx,vy,vz);	// point and surface normal
				}
			}// endif collisionGeom!=null

			if (childMeshes==null) return hpt;

			// ----- search submeshes for line hit ------------------
			for (var i:int=childMeshes.length-1; i>-1; i--)
			{
				var npt:VertexData = childMeshes[i].lineHitsMesh(lox,loy,loz,lvx,lvy,lvz,T);
				if (hpt==null ||
					npt!=null &&
					(npt.vx-lox)*(npt.vx-lox)+(npt.vy-loy)*(npt.vy-loy)+(npt.vz-loz)*(npt.vz-loz) <
					(hpt.vx-lox)*(hpt.vx-lox)+(hpt.vy-loy)*(hpt.vy-loy)+(hpt.vz-loz)*(hpt.vz-loz))
					hpt = npt;
			}

			return hpt;
		}//endfunction

		/**
		* given sphere center (ox,oy,oz) and radius r
		* returns {vx,vy,vz,nx,ny,nz} the 3D position and surface normal where sphere hits this mesh (optionally after applying transform T), or null
		*/
		public function sphereHitsMesh(ox:Number,oy:Number,oz:Number,r:Number,T:Matrix4x4=null) : Vector3D
		{
			if (transform==null) 	transform = new Matrix4x4();
			if (T==null)	T = transform;
			else			T = T.mult(transform);	// concat transform with self transform

			var hpt:Vector3D = null;
			if (collisionGeom!=null)
			{
				// ----- inverse transform line to object space ---------
				var invT:Matrix4x4 = T.inverse();
				var lox:Number = invT.aa*ox + invT.ab*oy + invT.ac*oz + invT.ad;	// transform point
				var loy:Number = invT.ba*ox + invT.bb*oy + invT.bc*oz + invT.bd;
				var loz:Number = invT.ca*ox + invT.cb*oy + invT.cc*oz + invT.cd;
				var lr:Number = r*invT.determinant3();

				//if (collisionGeom.sphereHitsBounds(lox,loy,loz,lr))
					hpt = collisionGeom.sphereHitsGeometry(lox,loy,loz,r);

				if (hpt!=null)
				{
					// ----- transform hit pt to global space ---------------
					hpt =new Vector3D(	T.aa*hpt.x + T.ab*hpt.y + T.ac*hpt.z + T.ad,	// un transform hit point
										T.ba*hpt.x + T.bb*hpt.y + T.bc*hpt.z + T.bd,
										T.ca*hpt.x + T.cb*hpt.y + T.cc*hpt.z + T.cd);
				}
			}// endif collisionGeom!=null

			if (childMeshes==null) return hpt;

			// ----- search submeshes for line hit ------------------
			for (var i:int=childMeshes.length-1; i>-1; i--)
			{
				var npt:Vector3D = childMeshes[i].sphereHitsMesh(ox,oy,oz,r,T);
				if (hpt==null ||
					npt!=null &&
					(npt.x-ox)*(npt.x-ox)+(npt.y-oy)*(npt.y-oy)+(npt.z-oz)*(npt.z-oz) <
					(hpt.x-ox)*(hpt.x-ox)+(hpt.y-oy)*(hpt.y-oy)+(hpt.z-oz)*(hpt.z-oz))
					hpt = npt;
			}

			return hpt;
		}//endfunction

		/**
		* get bounding box min in global space for static geometry mesh only _typeV
		*/
		public function minXYZ() : Vector3D
		{
			var minV:Vector3D = new Vector3D();
			if (dataType==_typeV) minV = estimateMinMax(transform,this,false);
			if (minV==null)	minV = new Vector3D(0,0,0);
			for (var i:int=0; i<childMeshes.length; i++)
			{	// scan through all child meshes
				var cm:Mesh = childMeshes[i];
				var cminV:Vector3D = estimateMinMax(transform.mult(cm.transform),cm,false);
				if (cminV!=null)
				{
					if (cminV.x<minV.x) minV.x = cminV.x;
					if (cminV.y<minV.y) minV.y = cminV.y;
					if (cminV.z<minV.z) minV.z = cminV.z;
				}
			}
			return minV;
		}//endfunction

		/**
		* get bounding box max in global space for static geometry mesh only _typeV
		*/
		public function maxXYZ() : Vector3D
		{
			var maxV:Vector3D = new Vector3D();
			if (dataType==_typeV) maxV = estimateMinMax(transform,this,true);
			if (maxV==null)	maxV = new Vector3D(0,0,0);
			for (var i:int=0; i<childMeshes.length; i++)
			{	// scan through all child meshes
				var cm:Mesh = childMeshes[i];
				var cmaxV:Vector3D = estimateMinMax(transform.mult(cm.transform),cm,true);
				if (cmaxV!=null)
				{
					if (cmaxV.x>maxV.x) maxV.x = cmaxV.x;
					if (cmaxV.y>maxV.y) maxV.y = cmaxV.y;
					if (cmaxV.z>maxV.z) maxV.z = cmaxV.z;
				}
			}
			return maxV;
		}//endfunction

		/**
		*
		*/
		public static function setAntiAliasing(val:uint):void
		{
			antiAliasing = val;
			if (context3d==null) return;

			try {
				context3d.configureBackBuffer(viewWidth, viewHeight, antiAliasing, true);
				debugTrace("configure back buffer to, "+viewWidth+"x"+viewHeight);
			} catch (e:Error)
			{
				try {
					context3d.configureBackBuffer(viewWidth, viewHeight, antiAliasing, false);
					debugTrace("configure back buffer to, "+viewWidth+"x"+viewHeight+" depthAndStencil false");
				}
				catch (e:Error) {}
			}
		}//endfunction

		/**
		* calculate tangents for normal mapping, quite heavy calculation
		* input: [vx,vy,vz,nx,ny,nz,u,v,...]
		* output: [vx,vy,vz,nx,ny,nz,tx,ty,tz,u,v,...]
		*/
		public static var TBRV:Vector.<Vector3D> = null;
		public static function calcTangentBasis(idxs:Vector.<uint>,vData:Vector.<Number>) : Vector.<Number>
		{
			/*
			let a be vector from p to q
			let b be vector from p to r

			p(ax,ay) + q(bx,by) s.t    (y axis)
			p*ay + q*by = 1  ... (1)
			p*ax + q*bx = 0  ... (2)

			p*ax = -q*bx
			p = -q*bx/ax   ... (2a)
			sub in (1)

			-q*ay*bx/ax + q*by = 1
			q = 1/(by-ay*bx/ax)
			*/

			var i:int=0;
			var n:int=vData.length/8;
			var v:Vector3D = null;

			if (TBRV==null)	TBRV=new Vector.<Vector3D>();
			for (i=TBRV.length-1; i>=0; i--)	{v=TBRV[i]; v.x=0; v.y=0; v.z=0;}	// reset vector
			for (i=TBRV.length; i<n; i++)	TBRV.push(new Vector3D(0,0,0));

			n = idxs.length;
			for (i=0; i<n;)	// for each triangle
			{
				var i0:uint = idxs[i];	i++;	// tri point index 0
				var i1:uint = idxs[i];	i++;	// tri point index 1
				var i2:uint = idxs[i];	i++;	// tri point index 2

				var pax:Number = vData[i1*8+6] - vData[i0*8+6];
				var ax:Number = pax;
				do {
					var tmp:uint=i0; i0=i1; i1=i2; i2=tmp;
					ax = vData[i1*8+6] - vData[i0*8+6];
				} while (ax*ax>pax*pax);
				tmp=i2; i2=i1; i1=i0; i0=tmp;

				var p0:uint = i0*8+6;
				var p1:uint = i1*8+6;
				var p2:uint = i2*8+6;
				var tx:Number = vData[p0++];
				var ty:Number = vData[p0];
					ax		  = vData[p1++] - tx;	// vector a in uv space
				var	ay:Number = vData[p1] - ty;
				var bx:Number = vData[p2++] - tx;	// vector b in uv space
				var by:Number = vData[p2] - ty;
				var q:Number = 1/(by-ay*bx/ax);
				var p:Number = -q*bx/ax;

				// find tangent vector from p q
				p0 = i0*8;
				p1 = i1*8;
				p2 = i2*8;
				tx = vData[p0++];
				ty = vData[p0++];
				var tz:Number = vData[p0];
				ax = vData[p1++] - tx;
				ay = vData[p1++] - ty;
				var az:Number = vData[p1] - tz;		// vector a in object space
				p0 = i0*8;
				bx = vData[p2++] - tx;
				by = vData[p2++] - ty;
				var bz:Number = vData[p2] - tz;		// vector b in object space

				tx = p*ax+q*bx;
				ty = p*ay+q*by;
				tz = p*az+q*bz;
				v = TBRV[i0];		v.x+=tx; v.y+=ty; v.z+=tz; v.w++;
				v = TBRV[i1];		v.x+=tx; v.y+=ty; v.z+=tz; v.w++;
				v = TBRV[i2];		v.x+=tx; v.y+=ty; v.z+=tz; v.w++;
			}//endfor

			// ----- get tangent results for each corresponding point
			var R:Vector.<Number> = new Vector.<Number>();
			n = vData.length/8;
			for (i=0; i<n; i++)
			{
				v = TBRV[i];
				p0 = i*8+3;
				ax = vData[p0++];
				ay = vData[p0++];
				az = vData[p0];
				if (ax*ax+ay*ay+az*az>0)
				{	// cross product to make sure 90 degrees
					tx = v.y*az - v.z*ay;	// cross product tangent
					ty = v.z*ax - v.x*az;
					tz = v.x*ay - v.y*ax;
					var tl:Number = 1/Math.sqrt(tx*tx+ty*ty+tz*tz);
					tx*=tl; ty*=tl; tz*=tl;
				}
				p0 = i*8;
				R.push(	vData[p0++],vData[p0++],vData[p0++],	// vx,vy,vz
						vData[p0++],vData[p0++],vData[p0++],	// nx,ny,nz
						tx,ty,tz,								// tx,ty,tz
						vData[p0++],vData[p0++]);				// u,v
			}//endfor

			return R;
		}//endfunction

		/**
		* convenience function to find the bounding box of AABB (local bounding box) of mesh m
		*/
		private static function estimateMinMax(T:Matrix4x4,m:Mesh,findMax:Boolean=true) : Vector3D
		{
			// if bounds not calculated, calculate
			if (m.collisionGeom==null)	return null;

			var minXYZ:Vector3D = m.collisionGeom.minXYZ;
			var maxXYZ:Vector3D = m.collisionGeom.maxXYZ;

			// calculate eight corners of the bounding box
			var c1:Vector3D = T.transform(new Vector3D(minXYZ.x,minXYZ.y,minXYZ.z));
			var c2:Vector3D = T.transform(new Vector3D(maxXYZ.x,minXYZ.y,minXYZ.z));
			var c3:Vector3D = T.transform(new Vector3D(maxXYZ.x,maxXYZ.y,minXYZ.z));
			var c4:Vector3D = T.transform(new Vector3D(minXYZ.x,maxXYZ.y,minXYZ.z));
			var c5:Vector3D = T.transform(new Vector3D(minXYZ.x,minXYZ.y,maxXYZ.z));
			var c6:Vector3D = T.transform(new Vector3D(maxXYZ.x,minXYZ.y,maxXYZ.z));
			var c7:Vector3D = T.transform(new Vector3D(maxXYZ.x,maxXYZ.y,maxXYZ.z));
			var c8:Vector3D = T.transform(new Vector3D(minXYZ.x,maxXYZ.y,maxXYZ.z));

			if (findMax)
			return new Vector3D(Math.max(c1.x,c2.x,c3.x,c4.x,c5.x,c6.x,c7.x,c8.x),
								Math.max(c1.y,c2.y,c3.y,c4.y,c5.y,c6.y,c7.y,c8.y),
								Math.max(c1.z,c2.z,c3.z,c4.z,c5.z,c6.z,c7.z,c8.z));
			else
			return new Vector3D(Math.min(c1.x,c2.x,c3.x,c4.x,c5.x,c6.x,c7.x,c8.x),
								Math.min(c1.y,c2.y,c3.y,c4.y,c5.y,c6.y,c7.y,c8.y),
								Math.min(c1.z,c2.z,c3.z,c4.z,c5.z,c6.z,c7.z,c8.z));
		}//endfunction

		/**
		* center the mesh's origin position to its mean vertices center, useful for eliminating hit detect with bounding radius problem
		*/
		public function centerToGeometry(propagate:Boolean=false) : void
		{
			var mean:Vector3D = new Vector3D(0,0,0);

			if (dataType==_typeV && idxsData!=null && vertData!=null)
			{
				var n:int = vertData.length;
				for (var i:int=0; i<n; i+=11)
				{
					mean.x+=vertData[i];
					mean.y+=vertData[i+1];
					mean.z+=vertData[i+2];
				}//endfor

				mean.scaleBy(11/n);

				for (i=0; i<n; i+=11)
				{
					vertData[i]-=mean.x;
					vertData[i+1]-=mean.y;
					vertData[i+2]-=mean.z;
				}//endfor

				setGeometry(vertData,idxsData);
				if (transform==null) transform = new Matrix4x4();
				transform = transform.translate(mean.x,mean.y,mean.z);
			}

			if (propagate)
				for (i=childMeshes.length-1; i>-1; i--)
				{
					childMeshes[i].centerToGeometry(propagate);
					if (childMeshes[i].transform==null)	childMeshes[i].transform = new Matrix4x4();
					childMeshes[i].transform.translate(-mean.x,-mean.y,-mean.z);
				}
		}//endfunction

		/**
		* returns the position (vx,vy,vz) and direction & magnitude (nx,ny,nz) for line directly under cursor
		*/
		public static function cursorRay(cursorX:Number,cursorY:Number,nearZ:Number,farZ:Number) : VertexData
		{
			var sw:uint = viewWidth;
			var sh:uint = viewHeight;

			if (viewT==null)	viewT = getViewTransform(0,0,-10,0,0,0);

			// ----- view inverse matrix -----------------------------
			var inv:Matrix4x4 = viewT.inverse();

			// ----- calculate near and far point --------------------
			var mpx:Number = (cursorX-sw/2)/sw;
			var mpy:Number =-(cursorY-sh/2)/sw;
			var mpz:Number = focalL/2;

			var nm:Number = nearZ/mpz;	// near multiplier
			var fm:Number = farZ/mpz;	// far multiplier

			var nearT:Matrix4x4 = inv.mult(new Matrix4x4().translate(mpx*nm,mpy*nm,mpz*nm));
			var px:Number = nearT.ad;
			var py:Number = nearT.bd;
			var pz:Number = nearT.cd;
			var farT:Matrix4x4 = inv.mult(new Matrix4x4().translate(mpx*fm,mpy*fm,mpz*fm));
			var vx:Number = farT.ad-px;
			var vy:Number = farT.bd-py;
			var vz:Number = farT.cd-pz;
			return new VertexData(px,py,pz,vx,vy,vz);
		}//endfunction

		/**
		* returns the 2D stage position of the 3D point according to camera view
		*/
		public static function screenPosn(px:Number,py:Number,pz:Number) : Point
		{
			if (viewT==null)	viewT = new Matrix4x4();
			var nx:Number = viewT.aa*px+viewT.ab*py+viewT.ac*pz+viewT.ad;
			var ny:Number = viewT.ba*px+viewT.bb*py+viewT.bc*pz+viewT.bd;
			var nz:Number = viewT.ca*px+viewT.cb*py+viewT.cc*pz+viewT.cd;
			return new Point(	nx/nz*focalL*viewWidth/2+viewWidth/2,
							   -ny/nz*focalL*viewWidth/2+viewHeight/2);
		}//endfunction

		/**
		* sets camera to look from (px,py,pz) at (tx,ty,tz), camera is always oriented y up with elevation angle
		*/
		public static function setCamera(px:Number,py:Number,pz:Number,tx:Number,ty:Number,tz:Number,focalLength:Number=1,near:Number=1,far:Number=1000) : Matrix4x4
		{
			nearClip = Math.max(0,near);
			farClip = Math.max(0,far);
			focalL = Math.max(0,focalLength);
			nearClip = Math.min(near,far);
			farClip = Math.max(near,far);
			viewT = getViewTransform(px,py,pz,tx,ty,tz);
			camT = viewT.inverse();
			return camT.scale(1,1,1);	// duplicate and return
		}//endfunction

		/**
		* sets this mesh to be rendered under given lighting conditions
		* setup fragment program to handle ambient lighting and light points
		* lightPoints : [vx,vy,vz,r,g,b, vx,vy,vz,r,g,b, ...]
		*/
		public static function setPointLighting(lightPoints:Vector.<Number>=null) : void
		{
			var i:int=0;
			if (lightPoints==null)
				lightPoints = new Vector.<Number>();
			else
				lightPoints = lightPoints.slice();

			if (lightsConst==null || lightsConst.length/8 != lightPoints.length/6)
				stateId++;	// trigger recompile of shader codes

			for (i=3; i<=lightPoints.length; i+=3)
				lightPoints.splice(i++,0,1);	// [vx,vy,vz,1,r,g,b,1, vx,vy,vz,1,r,g,b,1, ...]
			lightsConst = lightPoints;
		}//endfunction

		/**
		* used to force normal movieclips update
		*/
		public static function blankRender() : void
		{
			if (context3d==null)	return;
			context3d.clear(0,0,0,1,0,0,0xFFFFFFFF);	// clear depth buffer to 0s
			context3d.present();
		}//endfunction

		/**
		* renders given mesh (branch) onto stage3D
		*/
		public static function renderBranch(stage:Stage,M:Mesh,shadows:Boolean=false,renderTarg:String="backBuffer",bgRGBA:Vector3D=null) : void
		{
			if (context3d==null)	{getContext(stage);	return;}

			var renderTime:int=getTimer();

			if (lightsConst==null)	setPointLighting(Vector.<Number>([0,focalL*10,0,  1.0,1.0,1.0]));	// light points

			var n:uint = lightsConst.length/8;	// number of lights

			if (viewT==null)	viewT = getViewTransform(0,0,-10,0,0,0);	// default if null

			// ----- resize stage3D if stage width/height changed ------------
			if (viewWidth!=stage.stageWidth || viewHeight!=stage.stageHeight)
			{
				debugTrace("resizing backBuffer");
				getContext(stage);
				return;
			}

			// ----- render depth cube maps for shadowing --------------------
			if (shadows)
			{
				renderLightDepthCubeMaps(M);
				context3d.setProgramConstantsFromVector("fragment", n*2+4, Vector.<Number>([256*256,256,1,1/256]));	// for calculating depth distances
			}

			// ----- clear screen buffer AFTER renderLightPOVDepths ----------
			if (renderTarg=="texture")
			{
				if (outTex==null) outTex = context3d.createTexture(1024,1024,Context3DTextureFormat.BGRA, true);
				context3d.setRenderToTexture(outTex,true,0);
			}
			else
			{
				context3d.setRenderToBackBuffer();
			}

			if (bgRGBA!=null)
				context3d.clear(bgRGBA.x,bgRGBA.y,bgRGBA.z,bgRGBA.w,0,0,0xFFFFFFFF);	// clear depth buffer to 0s
			else
				context3d.clear(0,0,0,1,0,0,0xFFFFFFFF);	// clear depth buffer to 0s

			context3d.setCulling(Context3DTriangleFace.BACK);
			_renderBranch(M,shadows);

			// ----- show current rendered stuffs ---------------------------
			//if (renderTarg=="bitmapData")	context3d.drawToBitmapData(toBmd);
			if (renderTarg!="texture")
				context3d.present();

			// ----- calculate performance stats ----------------------------
			renderTime=getTimer()-renderTime;
			var frameT:int=0;
			if (fTV==null) fTV = new Vector.<int>();
			if (fTV.length>0) frameT = getTimer()-fTV[fTV.length-1];
			fTV.push(getTimer());
			if (fTV.length>100) fTV.shift();
			var aveT:int = 0;
			for (var i:int=fTV.length-1; i>0; i--) aveT+=fTV[i]-fTV[i-1];
			aveT/=fTV.length-1;
			fpsStats = "stage3D:"+viewWidth+"x"+viewHeight+"  drawCalls:"+drawCalls+"  numMeshes:"+numMeshes+"  tris:"+trisRendered+"  fps:"+int(1000/aveT)+"  frameT:"+frameT+"  renderT:"+renderTime+"  Mem:"+int(System.totalMemory/1048576)+"MBs";
			drawCalls = 0;
			trisRendered = 0;
		}//endfunction

		/**
		*
		*/
		public static function renderWithBloom(stage:Stage,M:Mesh,blurX:int,blurY:int,cutOff:Number=0.9,intensity:Number=2,shadows:Boolean=false) : void
		{
			if (context3d==null)	{getContext(stage);	return;}
			prevType = -1;
			prevTex=null;
			prevEnv=null;
			prevNorm=null;
			prevProg=null;
			renderBranch(stage,M,shadows,"texture");
			if (bloomFilterData==null)
				bloomFilterData = new BloomFilterData(context3d);
			bloomFilterData.render(outTex,blurX,blurY,cutOff,intensity);
		}//endfunction

		/**
		* internal render call render mesh tree to whatever set buffer
		*/
		private static function _renderBranch(M:Mesh,shadows:Boolean=false):void
		{
			if (lightsConst==null)	setPointLighting(Vector.<Number>([0,focalL*10,0,  1.0,1.0,1.0]));	// light points
			var n:uint = lightsConst.length/8;	// number of lights

			// ----- set transform parameters for this mesh to context3d -----
			var aspect:Number = viewWidth/viewHeight;
			context3d.setProgramConstantsFromVector("vertex", 0, Vector.<Number>([nearClip,farClip,focalL,aspect]));	// set vc register 0

			context3d.setProgramConstantsFromVector("fragment", 0, Vector.<Number>([0,0.5,1,2]));	// fc0, useful constants

			// ----- calculate and upload point lighting positions -----------
			var lightData:Vector.<Number> = lightsConst.slice();	// [lx,ly,lz,1,r,g,b,1, ...]
			for (var j:int=0; j<n; j++)
			{
				// light point posn transformed by viewT
				var lx:Number = lightData[j*8+0];		// original light point
				var ly:Number = lightData[j*8+1];
				var lz:Number = lightData[j*8+2];
				var tlx:Number = lx*viewT.aa + ly*viewT.ab + lz*viewT.ac + viewT.ad;	// transformed light point
				var tly:Number = lx*viewT.ba + ly*viewT.bb + lz*viewT.bc + viewT.bd;
				var tlz:Number = lx*viewT.ca + ly*viewT.cb + lz*viewT.cc + viewT.cd;
				lightData[j*8+0] = tlx;	lightData[j*8+1] = tly; lightData[j*8+2] = tlz;
				var shadowBiasFactor:Number = Math.max(0.001,(Math.sqrt(tlx*tlx+tly*tly+tlz*tlz)/focalL-1)*1.25);
				lightData[j*8+3] = shadowBiasFactor;	// for perspective shadow mapping...
				lightData[j*8+7] = Math.max(0,1-1/shadowBiasFactor);
			}//endfor
			context3d.setProgramConstantsFromVector("fragment", 4, lightData);

			// ----- get list of meshes to be rendered -----------------------
			var R:Vector.<Mesh> = new Vector.<Mesh>();
			M.flattenTree(new Matrix4x4(),R);
			R = R.sort(depthCompare);

			var rlen:uint = R.length;
			numMeshes = rlen;
			for (var i:int=0; i<rlen; i++)
			{
				M = R[i];

				// ----- prep for render if mesh is not yet prep
				if (M.dataType<0)	{/*type empty mesh*/}
				else
				{
					if (renderedWithShadows != shadows) {stateId++; renderedWithShadows = shadows;}
					if (M.stdProgram==null || M.builtOnState!=stateId) M.setContext3DBuffers(shadows); // build shader prog if incorrect

					if (M.dataType==_typeV || M.jointsData!=null)	// if plain geometry or joints data is valid
					{
						var T:Matrix4x4 = viewT.mult(M.workingTransform);		// transform for current mesh to be rendered
						// ----- set transform parameters for this mesh to context3d ----
						context3d.setProgramConstantsFromVector("vertex", 1, Vector.<Number>([T.aa,T.ab,T.ac,T.ad,T.ba,T.bb,T.bc,T.bd,T.ca,T.cb,T.cc,T.cd,0,0,0,1]));	// set vc register 1,2,3,4

						// ----- ambient, specular, fog factors for this mesh -----------
						context3d.setProgramConstantsFromVector("fragment", 1, Vector.<Number>([M.material.ambR, M.material.ambG, M.material.ambB,0]));					// r,g,b,0
						context3d.setProgramConstantsFromVector("fragment", 2, Vector.<Number>([M.material.specStr,M.material.specHard+1,M.material.specHard, 0]));	// st,h1,h0,0
						context3d.setProgramConstantsFromVector("fragment", 3, Vector.<Number>([M.material.fogR,M.material.fogG,M.material.fogB,M.material.fogFar]));	//

						// ----- clear off prev used buffers
						for (j=0; j<7; j++)	context3d.setVertexBufferAt(j, null);

						// ----- sets vertices info for this mesh to context3d ----------
						if (M.dataType==_typeV)
						{
							context3d.setVertexBufferAt(0, M.vertexBuffer, 0, "float3");		// va0 to expect vertices
							if (M.illuminable)
							{
								context3d.setVertexBufferAt(1, M.vertexBuffer, 3, "float3");		// va1 to expect normals
								if (M.normMapBuffer!=null)
									context3d.setVertexBufferAt(2, M.vertexBuffer, 6, "float3");		// va2 to expect tangents
							}
							context3d.setVertexBufferAt(3, M.vertexBuffer, 9, "float2");		// va3 to expect uvs
						}
						else if (M.dataType==_typeP)
						{
							context3d.setVertexBufferAt(0, M.vertexBuffer, 0, "float3");		// va0 to expect vertices
							context3d.setVertexBufferAt(1, M.vertexBuffer, 3, "float3");		// va1 to expect UV and idx
							context3d.setProgramConstantsFromVector("vertex", 5,M.jointsData);	// the joint transforms data
						}
						else if (M.dataType==_typeM)
						{
							context3d.setVertexBufferAt(0, M.vertexBuffer, 0, "float3");		// va0 to expect vertices
							context3d.setVertexBufferAt(3, M.vertexBuffer, 9, "float4");		// va3 to expect UV and idx
							if (M.illuminable)
							{
								context3d.setVertexBufferAt(1, M.vertexBuffer, 3, "float3");	// va1 to expect normals
								if (M.normMapBuffer!=null)
									context3d.setVertexBufferAt(2, M.vertexBuffer, 6, "float3");// va2 to expect tangents
							}
							context3d.setProgramConstantsFromVector("vertex", 5,M.jointsData);	// the meshes orientation and positions data
						}
						else if (M.dataType==_typeS)
						{
							context3d.setVertexBufferAt(0, M.vertexBuffer, 0, "float2");		// va0 to expect texU texV
							if (M.illuminable)
							{
								context3d.setVertexBufferAt(1, M.vertexBuffer, 2, "float4");	// va1 to expect wnx,wny,wnx,transIdx
								context3d.setVertexBufferAt(2, M.vertexBuffer, 6, "float4");	// va2 to expect wtx,wty,wtx,transIdx
							}
							context3d.setVertexBufferAt(3, M.vertexBuffer, 10, "float4");		// va3 to expect weight vertex 1
							context3d.setVertexBufferAt(4, M.vertexBuffer, 14,"float4");		// va4 to expect weight vertex 2
							context3d.setVertexBufferAt(5, M.vertexBuffer, 18,"float4");		// va5 to expect weight vertex 3
							context3d.setVertexBufferAt(6, M.vertexBuffer, 22,"float4");		// va6 to expect weight vertex 4
							context3d.setProgramConstantsFromVector("vertex", 5,M.jointsData);	// the joint transforms data
						}
						prevType = M.dataType;

						// ----- set program to use -------------------------------------
						var prog:Program3D = M.stdProgram;			// use standard program
						if (prevProg!=prog)		context3d.setProgram(prog);
						prevProg = prog;

						// ----- sets texture info for this mesh to context3d -----------
						if (prevTex!=M.textureBuffer) context3d.setTextureAt(0,M.textureBuffer);	// fs0 to hold texture data
						var envBuff:CubeTexture=null;
						var normBuff:Texture=null;
						var specBuff:Texture=null;
						if (n>0 && M.illuminable)
						{
							envBuff=M.envMapBuffer;
							normBuff=M.normMapBuffer;
							specBuff=M.specMapBuffer;
						}
						if (prevNorm!=normBuff) context3d.setTextureAt(1,normBuff);	// fs1 to hold normal map data
						if (prevSpec!=specBuff) context3d.setTextureAt(2,specBuff);	// fs2 to hold specular map data
						if (prevEnv!=envBuff) context3d.setTextureAt(3,envBuff);	// fs3 to hold env map data
						prevTex=M.textureBuffer;
						prevEnv=envBuff;
						prevNorm=normBuff;
						prevSpec=specBuff;

						// ----- set shadowing comparison depth texture to read from ----
						if (shadows && n>0 && M.illuminable)
							for (j=0; j<n; j++)	context3d.setTextureAt(4+j, lightDCMs[j]);	// 4..n to hold light POV depth textures
						else
							for (j=0; j<n; j++)	context3d.setTextureAt(4+j, null);			// 4..n clear light POV depth textures

						// ----- enable alpha blending if transparent texture -----------
						context3d.setDepthTest(M.depthWrite,"greater");			// whether to write to depth buffer
						context3d.setBlendFactors(M.blendSrc,M.blendDest);		// set to specified blending

						// ----- draw our triangles to screen ---------------------------
						context3d.drawTriangles(M.indexBuffer, 0,M.trisCnt);
						drawCalls++;
						trisRendered+=M.trisCnt;
					}
				}//endelse
			}//endfor
		}//endfunction

		/**
		* render mesh tree to light POV depth buffers for all light sources given mesh M
		*/
		public static function renderLightDepthCubeMaps(M:Mesh) : void
		{
			if (context3d==null)	{return;}

			// ----- set rendering blending and depth pass --------
			context3d.setBlendFactors("one","zero");
			context3d.setDepthTest(true,"greater");
			context3d.setCulling(Context3DTriangleFace.FRONT);

			// ----- prep depth textures for render ---------------
			var n:uint = lightsConst.length/8;
			if (lightDCMs==null)	lightDCMs = new Vector.<CubeTexture>();
			while (lightDCMs.length<n) lightDCMs.push(context3d.createCubeTexture(1024,"bgra", true));
			while (lightDCMs.length>n) lightDCMs.pop().dispose();

			// ----- depth to RGBA multipliers --------------------
			context3d.setProgramConstantsFromVector("fragment", 0, Vector.<Number>([256*256,256,1,1/256, 0,0,0,0])); 	// fc0, fc1
			context3d.setProgramConstantsFromVector("vertex", 0, Vector.<Number>([nearClip,farClip,focalL,1]));	// set vc register 0

			// ----- unbind all -----------------------------------
			var i:uint=0;
			for (i=0; i<8; i++)	context3d.setTextureAt(i, null);
			prevTex=null; prevEnv=null; prevNorm=null;

			var R:Vector.<Mesh> = new Vector.<Mesh>();
			M.flattenTree(new Matrix4x4(),R);	// get list of meshes to be rendered

			var Dir:Vector.<int> = Vector.<int>([1,0,0, -1,0,0, 0,1,0, 0,-1,0, 0,0,1, 0,0,-1]);

			for (var l:int=0; l<n; l++)			// for each light
			{
				var wlx:Number = lightsConst[l*8+0];	// point light position in world space
				var wly:Number = lightsConst[l*8+1];
				var wlz:Number = lightsConst[l*8+2];
				var lx:Number = viewT.aa*wlx + viewT.ab*wly + viewT.ac*wlz + viewT.ad;	// light posn in view space
				var ly:Number = viewT.ba*wlx + viewT.bb*wly + viewT.bc*wlz + viewT.bd;
				var lz:Number = viewT.ca*wlx + viewT.cb*wly + viewT.cc*wlz + viewT.cd;

				for (var d:int=0; d<6; d++)		// for each of cube map direction
				{
					// ----- clear buffer ---------------------------------
					context3d.setRenderToTexture(lightDCMs[l],true,0,d);
					context3d.clear(1,1,1,1,0,0,0xFFFFFFFF);	// depth buffer to 0s

					// ----- set to light POV -----------------------------
					var dirT:Matrix4x4 = Mesh.getViewTransform(0,0,0, Dir[d*3+0],Dir[d*3+1],Dir[d*3+2]);
					var lightViewT:Matrix4x4 = dirT.mult(viewT.translate(-lx,-ly,-lz));

					// ----- calculate cam vector in light coordinate space
					var camV:Vector3D = dirT.rotateVector(new Vector3D(-lx,-ly,-lz));
					camV.w =Math.max(0.001,(camV.length/focalL-1)*1.25);		// start bias from dist 1 onwards
					camV.normalize();
					context3d.setProgramConstantsFromVector("vertex",127,Vector.<Number>([camV.x,camV.y,camV.z,camV.w]));

					// ----- render each of the mesh ----------------------
					for (i=0; i<R.length; i++)
					{
						M = R[i];

						if (M.dataType<0)	{/*type empty mesh*/}
						else if (M.castsShadow && (M.dataType==_typeV || M.jointsData!=null))
						{
							if (M.depthProgram==null || M.builtOnState!=stateId) M.setContext3DBuffers(true);	// compile shader prog if absent

							prevType=M.dataType;	// so streams can be set correctly on next normal render

							// ----- set transform parameters for this mesh to context3d ----
							var T:Matrix4x4 = lightViewT.mult(M.workingTransform);	// determine object transform
							context3d.setProgramConstantsFromVector("vertex", 1, Vector.<Number>([T.aa,T.ab,T.ac,T.ad,T.ba,T.bb,T.bc,T.bd,T.ca,T.cb,T.cc,T.cd,0,0,0,1]));	// set vc register 1,2,3,4

							// ----- set precompiled AGAL instrs to render --------
							if (prevProg!=M.depthProgram) context3d.setProgram(M.depthProgram);	// this mesh program that will render to depth buffer
							prevProg=M.depthProgram;

							// ----- clear off prev buffers --------------------------
							for (var j:int=0; j<7; j++) context3d.setVertexBufferAt(j,null);

							// ----- sets vertices info for this mesh to context3d ----------
							if (M.dataType==_typeV)
							{
								context3d.setVertexBufferAt(0, M.vertexBuffer, 0, "float3");	// va0 to expect vertices
							}
							else if (M.dataType==_typeP)
							{
								context3d.setVertexBufferAt(0, M.vertexBuffer, 0, "float3");	// va0 to expect vertices
								context3d.setVertexBufferAt(1, M.vertexBuffer, 3, "float3");	// va1 to expect UV and idx
								context3d.setProgramConstantsFromVector("vertex", 5,M.jointsData);	// the joint transforms data
							}
							else if (M.dataType==_typeM)
							{
								context3d.setVertexBufferAt(0, M.vertexBuffer, 0, "float3");	// va0 to expect vertices
								context3d.setVertexBufferAt(3, M.vertexBuffer, 9, "float4")		// va3 to expect UV and idx, idx+1
								context3d.setProgramConstantsFromVector("vertex", 5,M.jointsData);	// the joint transforms data
							}
							else if (M.dataType==_typeS)
							{
								context3d.setVertexBufferAt(0, M.vertexBuffer, 0, "float2");	// va0 to expect texU texV
								context3d.setVertexBufferAt(3, M.vertexBuffer, 10,"float4");	// va2 to expect weight vertex,transIdx
								context3d.setVertexBufferAt(4, M.vertexBuffer, 14,"float4");	// va3 to expect weight vertex,transIdx
								context3d.setVertexBufferAt(5, M.vertexBuffer, 18,"float4");	// va4 to expect weight vertex,transIdx
								context3d.setVertexBufferAt(6, M.vertexBuffer, 22,"float4");	// va5 to expect weight vertex,transIdx
								context3d.setProgramConstantsFromVector("vertex", 5,M.jointsData);	// the joint transforms data
							}

							// ----- draw our triangle to screen starting fron tri 0 --------
							context3d.drawTriangles(M.indexBuffer, 0,M.trisCnt);
							drawCalls++;
							trisRendered+=M.trisCnt;
						}
					}//endfor

				}//endfor d
			}//endfor l
		}//endfunction

		/**
		* creates the environmental cube map at given position
		*/
		public static function renderEnvCubeTex(stage:Stage,M:Mesh,cTex:CubeTexture,cx:Number,cy:Number,cz:Number):void
		{
			if (context3d==null)	{getContext(stage);	return;}

			context3d.setCulling(Context3DTriangleFace.BACK);

			context3d.setRenderToTexture(cTex, true, 0, 0);
			context3d.clear(0,0,0,1,0,0,0xFFFFFFFF);	// clear depth buffer to 0s
			Mesh.setCamera(	cx,cy,cz,  cx+1,cy,cz,  1,0.01);		// posn,lookAt,focalL,zNear
			_renderBranch(M);

			context3d.setRenderToTexture(cTex, true, 0, 1);
			context3d.clear(0,0,0,1,0,0,0xFFFFFFFF);	// clear depth buffer to 0s
			Mesh.setCamera(	cx,cy,cz,  cx-1,cy,cz,  1,0.01);		// posn,lookAt,focalL,zNear
			_renderBranch(M);

			context3d.setRenderToTexture(cTex, true, 0, 2);
			context3d.clear(0,0,0,1,0,0,0xFFFFFFFF);	// clear depth buffer to 0s
			Mesh.setCamera(	cx,cy,cz,  cx,cy+1,cz,  1,0.01);		// posn,lookAt,focalL,zNear
			_renderBranch(M);

			context3d.setRenderToTexture(cTex, true, 0, 3);
			context3d.clear(0,0,0,1,0,0,0xFFFFFFFF);	// clear depth buffer to 0s
			Mesh.setCamera(	cx,cy,cz,  cx,cy-1,cz,  1,0.01);		// posn,lookAt,focalL,zNear
			_renderBranch(M);

			context3d.setRenderToTexture(cTex, true, 0, 4);
			context3d.clear(0,0,0,1,0,0,0xFFFFFFFF);	// clear depth buffer to 0s
			Mesh.setCamera(	cx,cy,cz,  cx,cy,cz+1,  1,0.01);		// posn,lookAt,focalL,zNear
			_renderBranch(M);

			context3d.setRenderToTexture(cTex, true, 0, 5);
			context3d.clear(0,0,0,1,0,0,0xFFFFFFFF);	// clear depth buffer to 0s
			Mesh.setCamera(	cx,cy,cz,  cx,cy,cz-1,  1,0.01);		// posn,lookAt,focalL,zNear
			_renderBranch(M);

		}//endfunction

		/**
		* returns scene transform matrix eqv of camera looking from (px,py,pz) at point (tx,ty,tz)
		*/
		public static function getViewTransform(px:Number,py:Number,pz:Number,tx:Number,ty:Number,tz:Number) : Matrix4x4
		{
			var vx:Number = tx-px;
			var vy:Number = ty-py;
			var vz:Number = tz-pz;
			var vl:Number = Math.sqrt(vx*vx+vy*vy+vz*vz);
			var roty:Number = Math.atan2(vx,vz);
			var rotx:Number = Math.atan2(-vy,Math.sqrt(vx*vx+vz*vz));
			//return new Matrix4x4().translate(-tx,-ty,-tz).rotY(-roty).rotX(-rotx).translate(0,0,vl);
			return new Matrix4x4().translate(-px,-py,-pz).rotY(-roty).rotX(-rotx);
		}//endfunction

		/**
		* convenience function just to get context once and configure back buffer
		*/
		public static function getContext(stage:Stage,callBack:Function=null) : void
		{
			debugTrace("getContext");

			function onContext(ev:Event) : void
			{
				gettingContext=false;
				var stage3d:Stage3D=Stage3D(ev.currentTarget);
				context3d=stage3d.context3D;
				context3d.enableErrorChecking=false;	//**********************************
				debugTrace("got context3d, driverInfo:"+context3d.driverInfo);
				configBackBufferAndCallBack();
			}//endfunction

			function configBackBufferAndCallBack() : void
			{
				viewWidth = stage.stageWidth;
				viewHeight = stage.stageHeight;
				try {
					context3d.configureBackBuffer(viewWidth, viewHeight, antiAliasing, true);
					debugTrace("configure back buffer to, "+viewWidth+"x"+viewHeight);
				} catch (e:Error)
				{
					try {
						context3d.configureBackBuffer(viewWidth, viewHeight, antiAliasing, false);
						debugTrace("configure back buffer to, "+viewWidth+"x"+viewHeight+" depthAndStencil false");
					}
					catch (e:Error)
					{
						debugTrace("error configuring back buffer to, "+viewWidth+"x"+viewHeight+"\n"+e);
					}
				}

				if (callBack!=null) callBack();
			}//endfunction

			if (context3d==null)
			{
				if (gettingContext) return;
				gettingContext=true;
				stage.stage3Ds[0].addEventListener(Event.CONTEXT3D_CREATE, onContext);
				stage.stage3Ds[0].requestContext3D();
				return;
			}
			else configBackBufferAndCallBack();
		}//endfunction

		/**
		* returns ordering determination of meshA to meshB so alpha rendering is correct
		*/
		private static function depthCompare(meshA:Mesh,meshB:Mesh) : int
		{
			var dA:int = int.MAX_VALUE;	//  weird
			var dB:int = int.MAX_VALUE;	// why???
			if (meshA.blendSrc!="one")
			{
				var ta:Matrix4x4 = meshA.workingTransform;
				dA = ta.cd;		// compare z
			}
			if (meshB.blendSrc!="one")
			{
				var tb:Matrix4x4 = meshB.workingTransform;
				dB = tb.cd;		// compare z
			}
			if (dB>dA)
				return 1;
			else
				return -1;		// dB-dA (descending)  dA-dB (ascending)
		}//endfunction

		/**
		* create a sphere of given texture
		*/
		public static function createSphere(r:Number,lon:uint=32,lat:uint=16,tex:BitmapData=null,soft:Boolean=true,fromLat:uint=0,toLat:uint=uint.MAX_VALUE) : Mesh
		{
			var S:Vector.<Number> = new Vector.<Number>();
			var i:int = fromLat;
			toLat = Math.min(toLat, lat);
			while (i<toLat)
			{
				var sinL0:Number = Math.sin(Math.PI*i/lat);
				var sinL1:Number = Math.sin(Math.PI*(i+1)/lat);
				var cosL0:Number = Math.cos(Math.PI*i/lat);
				var cosL1:Number = Math.cos(Math.PI*(i+1)/lat);
				var A:Vector.<Number> = createTrianglesBand(sinL0*r,
															sinL1*r,
															-cosL0*r,
															-cosL1*r,
															lon,soft);

				var _vdiv:Number = toLat - fromLat;
				// ----- adjust UVs of mesh to wrap entire sphere instead
				for (var j:int=0; j<A.length; j+=8)
				{
					A[j+7]=(i-fromLat)/_vdiv+A[j+7]/_vdiv;
					if (soft)
					{	// recalculate normals
						var nx:Number = A[j+0];
						var ny:Number = A[j+1];
						var nz:Number = A[j+2];
						var nl:Number = Math.sqrt(nx*nx+ny*ny+nz*nz);
						nx/=nl; ny/=nl; nz/=nl;
						A[j+3]=nx; A[j+4]=ny; A[j+5]=nz;
					}
				}
				S = S.concat(A);
				i++;
			}//endfor

			var M:Mesh = new Mesh();
			M.createGeometry(S);
			M.setTexture(tex);
			return M;
		}//endfunction

		/**
		* create a doughnut shape with band radius r1, thickness r2, of m segments and made of n cylinders
		*/
		public static function createTorus(r1:Number,r2:Number,m:int=32,n:int=8,tex:BitmapData=null,soft:Boolean=true) : Mesh
		{
			var T:Vector.<Number> = new Vector.<Number>();
			var i:int=0;
			while (i<n)
			{
				var A:Vector.<Number> = createTrianglesBand(r1-r2*Math.cos(i/n*Math.PI*2),
															r1-r2*Math.cos((i+1)/n*Math.PI*2),
															-r2*Math.sin(i/n*Math.PI*2),
															-r2*Math.sin((i+1)/n*Math.PI*2),
															m,soft);

				// ----- adjust UVs of mesh to wrap entire torus instead
				var F:Vector.<int> = Vector.<int>([0,0,1,1,0,1]);
				for (var j:int=0; j<A.length; j+=8)
				{
					A[j+7]=i/n+A[j+7]/n;
					if (soft)
					{	// 112212
						var stp:int = F[(j/8)%6];	// step +1 or step
						var lon:int = int(j/48);	// current longitude
						var ang:Number = (lon+stp)/m*Math.PI*2;
						var cx:Number = r1*Math.sin(ang);
						var cy:Number = r1*Math.cos(ang);
						var cz:Number = 0;
						var nx:Number = A[j+0]-cx;
						var ny:Number = A[j+1]-cy;
						var nz:Number = A[j+2]-cz;
						var nl:Number = Math.sqrt(nx*nx+ny*ny+nz*nz);
						nx/=nl; ny/=nl; nz/=nl;

						A[j+3]=nx; A[j+4]=ny; A[j+5]=nz;
					}
				}
				T=T.concat(A);
				i++;
			}//endfunction

			var M:Mesh = new Mesh();
			M.createGeometry(T);
			M.setTexture(tex);
			return M;
		}//endfunction

		/**
		* create a cylinder of radius r1,r2 vertical posns z1,z2 of n segments
		*/
		public static function createCylinder(r1:Number,r2:Number,z1:Number,z2:Number,n:int,tex:BitmapData=null,soft:Boolean=true) : Mesh
		{
			var m:Mesh = new Mesh();
			m.createGeometry(createTrianglesBand(r1,r2,z1,z2,n,soft));
			m.setTexture(tex);
			return m;
		}//endfunction

		/**
		* creates a bullet streak
		*/
		public static function createStreak(l:Number,w:Number,tex:BitmapData=null,soft:Boolean=true) :Mesh
		{
			var r:Number = 1/6;		// ratio of widest point along length
			var v1:Vector.<Number> = createTrianglesBand(w/2,0,0,l*r,5,soft);
			var v2:Vector.<Number> = createTrianglesBand(0,w/2,-l*(1-r),0,5,soft);

			// ----- adjust UVs to extend entire streak instead
			for (var j:int=0; j<v1.length; j+=8)	v1[j+7] = (1-v1[j+7])*r;
			for (j=0; j<v2.length; j+=8)	v2[j+7]= (1-v2[j+7])*(1-r)+r;


			while (v2.length>0)	v1.push(v2.shift());
			var m:Mesh = new Mesh();
			m.createGeometry(v1);
			m.setTexture(tex);
			return m;
		}//endfunction

		/**
		* creates a circular band of triangles of specified r1,r2 z1,z2
		*/
		public static function createTrianglesBand(r1:Number,r2:Number,z1:Number,z2:Number,n:int,soft:Boolean=true) : Vector.<Number>
		{
			var A:Vector.<Number> = new Vector.<Number>();
			var i:int=0;
			while (i<n)
			{
				var a1:Number = i/n*Math.PI*2;
				var a2:Number = (i+1)/n*Math.PI*2;

				var sin_a1:Number = Math.sin(a1);
				var sin_a2:Number = Math.sin(a2);
				var cos_a1:Number = Math.cos(a1);
				var cos_a2:Number = Math.cos(a2);

				if (soft)	// apply Smooth Shading
				{
					var mz:Number = (z1+z2)/2;
					if (r2!=0) A.push(	sin_a1*r1,cos_a1*r1,z1,	// vertex
										sin_a1*r1,cos_a1*r1,z1,	// normal
										i/n,0,
										sin_a1*r2,cos_a1*r2,z2,	// vertex
										sin_a1*r2,cos_a1*r2,z2,	// normal
										i/n,1,
										sin_a2*r2,cos_a2*r2,z2,	// vertex
										sin_a2*r2,cos_a2*r2,z2,	// normal
										(i+1)/n,1);
					if (r1!=0) A.push(	sin_a2*r1,cos_a2*r1,z1,	// vertex
										sin_a2*r1,cos_a2*r1,z1,	// normal
										(i+1)/n,0,
										sin_a1*r1,cos_a1*r1,z1,	// vertex
										sin_a1*r1,cos_a1*r1,z1,	// normal
										i/n,0,
										sin_a2*r2,cos_a2*r2,z2,	// vertex
										sin_a2*r2,cos_a2*r2,z2,	// normal
										(i+1)/n,1);
				}
				else
				{
					if (r2!=0) A.push(	sin_a1*r1,cos_a1*r1,z1,	// vertex
									 	0,0,0,	// normal
										i/n,0,
										sin_a1*r2,cos_a1*r2,z2,	// vertex
										0,0,0,	// normal
										i/n,1,
										sin_a2*r2,cos_a2*r2,z2,	// vertex
										0,0,0,	// normal
										(i+1)/n,1);
					if (r1!=0) A.push(	sin_a2*r1,cos_a2*r1,z1,	// vertex
									 	0,0,0,	// normal
										(i+1)/n,0,
										sin_a1*r1,cos_a1*r1,z1,	// vertex
										0,0,0,	// normal
										i/n,0,
										sin_a2*r2,cos_a2*r2,z2,	// vertex
										0,0,0,	// normal
										(i+1)/n,1);
				}
				i++;
			}//endfor

			return A;
		}//endfunction

		/**
		* creates a texture cube from given square texture
		*/
		public static function createCube(w:Number=1,h:Number=1,d:Number=1,tex:BitmapData=null,soft:Boolean=true) : Mesh
		{
			w/=2;
			h/=2;
			d/=2;
			var V:Vector.<Number> = Vector.<Number>([-w,-h,-d,  w,-h,-d,  w,h,-d,  -w,h,-d,
													 -w,-h, d,  w,-h, d,  w,h, d,  -w,h, d]);

			var I:Vector.<uint> = Vector.<uint>([0,3,1, 1,3,2,	// front
												 1,2,5, 5,2,6,	// right
												 5,6,4, 4,6,7,	// back
												 4,7,0, 0,7,3,	// left
												 4,0,5, 5,0,1,	// top
												 3,7,2, 2,7,6]);// bottom

			var U:Vector.<Number> = Vector.<Number>([0,1, 0,0, 1,1, 1,1, 0,0, 1,0]);

			var i:uint=0;
			var ul:uint=U.length;
			var VData:Vector.<Number> = new Vector.<Number>();
			if (soft)
			{
				for (i=0; i<I.length; i+=3)
				VData.push(	V[I[i+0]*3+0],V[I[i+0]*3+1],V[I[i+0]*3+2],	// vertex a
							V[I[i+0]*3+0],V[I[i+0]*3+1],V[I[i+0]*3+2],	// normal a
							U[i*2%ul+0],U[i*2%ul+1],
							V[I[i+1]*3+0],V[I[i+1]*3+1],V[I[i+1]*3+2],	// vertex b
							V[I[i+1]*3+0],V[I[i+1]*3+1],V[I[i+1]*3+2],	// normal b
							U[i*2%ul+2],U[i*2%ul+3],
							V[I[i+2]*3+0],V[I[i+2]*3+1],V[I[i+2]*3+2],	// vertex c
							V[I[i+2]*3+0],V[I[i+2]*3+1],V[I[i+2]*3+2],	// normal c
							U[i*2%ul+4],U[i*2%ul+5]);
			}
			else
			{
				for (i=0; i<I.length; i+=3)
				VData.push(	V[I[i+0]*3+0],V[I[i+0]*3+1],V[I[i+0]*3+2],	// vertex a
							0,0,0,	// normal a
							U[i*2%ul+0],U[i*2%ul+1],
							V[I[i+1]*3+0],V[I[i+1]*3+1],V[I[i+1]*3+2],	// vertex b
							0,0,0,	// normal b
							U[i*2%ul+2],U[i*2%ul+3],
							V[I[i+2]*3+0],V[I[i+2]*3+1],V[I[i+2]*3+2],	// vertex c
							0,0,0,	// normal c
							U[i*2%ul+4],U[i*2%ul+5]);
			}

			var m:Mesh = new Mesh();
			m.createGeometry(VData);
			m.setTexture(tex);
			return m;
		}//endfunction

		/**
		* creates a texture tetra from given square texture
		*/
		public static function createTetra(l:Number=1,tex:BitmapData=null,soft:Boolean=true) : Mesh
		{
			// ----- front point
			var ax:Number = 0;
			var ay:Number = l/2/Math.sqrt(3)*2;
			var az:Number = 0;

			// ----- back left point
			var bx:Number =-l/2;
			var by:Number =-l/2/Math.sqrt(3);
			var bz:Number = 0;

			// ----- back right point
			var cx:Number = l/2;
			var cy:Number =-l/2/Math.sqrt(3);
			var cz:Number = 0;

			// ----- top point
			var dx:Number = 0;
			var dy:Number = 0;
			var dz:Number = Math.sqrt( l*l/4*3 - cy*cy );

			az-=l-dz;
			bz-=l-dz;
			cz-=l-dz;
			dz-=l-dz;

			var VData:Vector.<Number> = new Vector.<Number>();
			if (soft)
			{
				VData.push(	ax,ay,az,
							ax,ay,az,
							1/2,1-1/2/Math.sqrt(3),
							cx,cy,cz,
							cx,cy,cz,
							0,1,
							bx,by,bz,
							bx,by,bz,
							1,1);
				VData.push(	dx,dy,dz,
							dx,dy,dz,
							1/2,1-1/2/Math.sqrt(3),
							ax,ay,az,
							ax,ay,az,
							0,1,
							bx,by,bz,
							bx,by,bz,
							1,1);
				VData.push(	dx,dy,dz,
							dx,dy,dz,
							1/2,1-1/2/Math.sqrt(3),
							cx,cy,cz,
							cx,cy,cz,
							0,1,
							ax,ay,az,
							ax,ay,az,
							1,1);
				VData.push(	dx,dy,dz,
							dx,dy,dz,
							1/2,1-1/2/Math.sqrt(3),
							bx,by,bz,
							bx,by,bz,
							0,1,
							cx,cy,cz,
							cx,cy,cz,
							1,1);
			}
			else
			{
				VData.push( ax,ay,az,
							0,0,0,
							1/2,1-1/2/Math.sqrt(3),
							cx,cy,cz,
							0,0,0,
							0,1,
							bx,by,bz,	// bottom face
							0,0,0,			// normals
							1,1);		// UVs
				VData.push(	dx,dy,dz,
							0,0,0,
							1/2,1-1/2/Math.sqrt(3),
							ax,ay,az,
							0,0,0,
							0,1,
							bx,by,bz,	// front left
							0,0,0,			// normals
							1,1);		// UVs
				VData.push(	dx,dy,dz,
							0,0,0,
							1/2,1-1/2/Math.sqrt(3),
							cx,cy,cz,
							0,0,0,
							0,1,
							ax,ay,az,	// front right
							0,0,0,			// normals
							1,1);		// UVs
				VData.push(	dx,dy,dz,
							0,0,0,
							1/2,1-1/2/Math.sqrt(3),
							bx,by,bz,
							0,0,0,
							0,1,
							cx,cy,cz,	// back
							0,0,0,			// normals
							1,1);		// UVs
			}
			var m:Mesh = new Mesh();
			m.createGeometry(VData);
			m.setTexture(tex);
			return m;
		}//endfunction

		/**
		* create a transformable bmp plane in space default at origin perpenticular to z axis
		*/
		public static function createPlane(w:Number=1,h:Number=1,tex:BitmapData=null) : Mesh
		{
			var VData:Vector.<Number> = new Vector.<Number>();
			VData.push( w/2,-h/2,0,		// tr
						0,0,-1,			// tr normal
						1,1,			// tr UV
						-w/2,-h/2,0,	// tl
						0,0,-1,			// tl normal
						0,1,			// tl UV
						-w/2, h/2,0,	// bl
						0,0,-1,			// bl normal
						0,0);			// bl UV
			VData.push(	w/2,-h/2,0,		// tr
						0,0,-1,			// tr normal
						1,1,			// tr UV
						-w/2, h/2,0,	// bl
						0,0,-1,			// bl normal
						0,0,			// bl UV
						w/2, h/2,0,		// br
						0,0,-1,			// br normal
						1,0);			// br UV
			var m:Mesh = new Mesh();
			m.createGeometry(VData);
			m.setTexture(tex);
			return m;
		}//endfunction

		/**
		* returns rows*cols number of mesh m and distribute uv to rows and cols
		*/
		public static function mosaic(m:Mesh,rows:int,cols:int) : Vector.<Mesh>
		{
			if (rows<1) rows=1;
			if (cols<1) cols=1;
			var R:Vector.<Mesh> = new Vector.<Mesh>();
			if (m.dataType!=_typeV)	return R;

			for (var i:int=0; i<rows; i++)
				for (var j:int=0; j<cols; j++)
				{
					var nm:Mesh = m.clone();
					nm.vertData = nm.vertData.slice();
					for (var k:int=0; k<nm.vertData.length; k+=11)
					{
						nm.vertData[k+9] = (j + nm.vertData[k+6])/cols;
						nm.vertData[k+10] = (i + nm.vertData[k+7])/rows;
					}
					nm.setGeometry(nm.vertData,nm.idxsData);
					R.push(nm);
				}

			return R;
		}//endfunction

		/**
		* generates a terrain mesh from given height map data with specified channel max 128*128
		*/
		public static function createHeightMap(map:BitmapData,f:Number=1,channel:uint=0,tex:BitmapData=null) : Mesh
		{
			channel = Math.min(3,channel);

			// ----- generate vertices data -------------------------
			var V:Vector.<Number> = new Vector.<Number>();
			var w:int =map.width;
			var h:int = map.height;
			for (var x:int=0; x<w; x++)
				for (var y:int=0; y<h; y++)
				{
					var th:Number = ((map.getPixel(x,y)>>(channel*8))&0xFF)/255 - 0.5;	// terrain height at point
					V.push(	x/(w-1)-0.5,th*f,y/(h-1)-0.5,			// vertex
							0,0,0,								// normal
							x/(w-1),y/(h-1));					// uv
				}

			// ----- generate indices data --------------------------
			var I:Vector.<uint> = new Vector.<uint>();
			for (x=0; x<w-1; x++)
				for (y=0; y<h-1; y++)
				{
					I.push(	x*h+y,(x+1)*h+(y+1),(x+1)*h+y,	// tri 1
							x*h+y,x*h+(y+1),(x+1)*h+(y+1));	// tri 2
				}

			// ----- calculate normals ------------------------------
			var N:Vector.<Vector3D> = new Vector.<Vector3D>(V.length/8);
			for (var i:int=0; i<I.length; i+=3)
			{
				var ax:Number = V[I[i+0]*8+0];
				var ay:Number = V[I[i+0]*8+1];
				var az:Number = V[I[i+0]*8+2];
				var bx:Number = V[I[i+1]*8+0];
				var by:Number = V[I[i+1]*8+1];
				var bz:Number = V[I[i+1]*8+2];
				var cx:Number = V[I[i+2]*8+0];
				var cy:Number = V[I[i+2]*8+1];
				var cz:Number = V[I[i+2]*8+2];
				// ----- calculate default normals ------------------------
				var px:Number = bx - ax;
				var py:Number = by - ay;
				var pz:Number = bz - az;
				var qx:Number = cx - ax;
				var qy:Number = cy - ay;
				var qz:Number = cz - az;
				// ----- normal by determinant
				var nx:Number = py*qz-pz*qy;	//	unit normal x for the triangle
				var ny:Number = pz*qx-px*qz;	//	unit normal y for the triangle
				var nz:Number = px*qy-py*qx;	//	unit normal z for the triangle
				var nl:Number = Math.sqrt(nx*nx+ny*ny+nz*nz);
				nx/=nl; ny/=nl; nz/=nl;
				for (var j:int=0; j<3; j++)
				{
					if (N[I[i+j]]==null)
						N[I[i+j]] = new Vector3D(nx,ny,nz);
					else
					{
						N[I[i+j]].x += nx;
						N[I[i+j]].y += ny;
						N[I[i+j]].z += nz;
					}
				}
			}

			// ----- normalize normals and add to V ---------------------------
			for (i=0; i<N.length; i++)
			{
				N[i].normalize();
				V[i*8+3] = N[i].x;
				V[i*8+4] = N[i].y;
				V[i*8+5] = N[i].z;
			}

			// ----- genertates tangents and sets geometry data to mesh -------
			var m:Mesh = new Mesh();
			m.setGeometry(calcTangentBasis(I,V),I);
			m.setTexture(tex);		// can be null tex
			return m;
		}//endfunction

		/**
		* create a rigging bone primitive shape of specified length
		*/
		public static function createBone(len:Number,tex:BitmapData=null) : Mesh
		{
			var C1:Vector.<Number> = createTrianglesBand(0,len/8,0,len/5,3);
			var C2:Vector.<Number> = createTrianglesBand(len/8,len/50,len/5,len,3);

			var r:Number = len/10;
			var lon:uint = 12;
			var lat:uint = 6;
			var S:Vector.<Number> = new Vector.<Number>();
			var i:int=0;
			while (i<lat)
			{
				var A:Vector.<Number> = createTrianglesBand(	Math.sin(Math.PI*i/lat)*r,
																Math.sin(Math.PI*(i+1)/lat)*r,
																-Math.cos(Math.PI*i/lat)*r,
																-Math.cos(Math.PI*(i+1)/lat)*r,
																lon);

				// ----- adjust UVs of mesh to wrap entire torus instead
				for (var j:int=0; j<A.length; j+=8)	A[j+7]=i/lat+A[j+7]/lat;

				S = S.concat(A);
				i++;
			}//endfor

			var R:Vector.<Number> = C1.concat(C2.concat(S));
			var m:Mesh = new Mesh();
			m.createGeometry(R);
			m.setTexture(tex);
			return m;
		}//endfunction

		/**
		* given line L(o:pt,v:vect) returns its intersection on triangle T(a:pt,b:pt,c:pt)
		*/
		public static function lineTriangleIntersection(lox:Number,loy:Number,loz:Number,
														lvx:Number,lvy:Number,lvz:Number,
														tax:Number,tay:Number,taz:Number,
														tbx:Number,tby:Number,tbz:Number,
														tcx:Number,tcy:Number,tcz:Number,
														chkInTri:Boolean=true) : Vector3D
		{
			var tpx:Number = tbx - tax;		// tri side vector from a to b
			var tpy:Number = tby - tay;		// tri side vector from a to b
			var tpz:Number = tbz - taz;		// tri side vector from a to b

			var tqx:Number = tcx - tax;		// tri side vector from a to c
			var tqy:Number = tcy - tay;		// tri side vector from a to c
			var tqz:Number = tcz - taz;		// tri side vector from a to c

			// normal by determinant Tn
			var tnx:Number = tpy*tqz-tpz*tqy;	//	normal x for the triangle
			var tny:Number = tpz*tqx-tpx*tqz;	//	normal y for the triangle
			var tnz:Number = tpx*tqy-tpy*tqx;	//	normal z for the triangle

			// let X be the intersection point, then equation of triangle plane Tn.(X-Ta) = 0
			// but X = Lo+Lv*k   =>   Tn.(Lo+Lv*k-Ta) = 0    =>   Tn.Lv*k + Tn.(Lo-Ta) = 0
			// k = (Ta-Lo).Tn/Lv.Tn
			// denom!=0 => there is intersection in the plane of tri

			var denom:Number = lvx*tnx+lvy*tny+lvz*tnz;
			if (denom==0)	return null;		// return no intersection or line in plane...

			var num:Number = (tnx*(tax-lox) + tny*(tay-loy) + tnz*(taz-loz));
			var k:Number = num/denom;
			if (chkInTri && (k<0 || k>1)) return null;	// return no segment intersection

			var ix:Number = lox+lvx*k - tax;	// vector to segment intersection on triangle plane
			var iy:Number = loy+lvy*k - tay;	// vector to segment intersection on triangle plane
			var iz:Number = loz+lvz*k - taz;	// vector to segment intersection on triangle plane

			// find scalars along triangle sides P and Q s.t. sP+tQ = I
			// s = (p.q)(w.q)-(q.q)(w.p)/(p.q)(p.q)-(p.p)(q.q)
			// t = (p.q)(w.p)-(p.p)(w.q)/(p.q)(p.q)-(p.p)(q.q)
			var p_p:Number = tpx*tpx+tpy*tpy+tpz*tpz;
			var q_q:Number = tqx*tqx+tqy*tqy+tqz*tqz;
			var p_q:Number = tpx*tqx+tpy*tqy+tpz*tqz;
			var w_p:Number =  ix*tpx+ iy*tpy+ iz*tpz;
			var w_q:Number =  ix*tqx+ iy*tqy+ iz*tqz;

			denom = p_q*p_q - p_p*q_q;
			var s:Number = (p_q*w_q - q_q*w_p)/denom;
			var t:Number = (p_q*w_p - p_p*w_q)/denom;

			if (chkInTri && (s<0 || t<0 || s+t>1)) return null;	// return intersection outside triangle

			return new Vector3D(tax+s*tpx+t*tqx,	// return intersection point within tri
								tay+s*tpy+t*tqy,	// return intersection point within tri
								taz+s*tpz+t*tqz,1);	// return intersection point within tri
		}//endfunction

		/**
		* parses a given obj format string data s to mesh with null texture
		* Mtls: [id1,bmd1,id2,bmd2,...]
		*/
		public static function parseObjToMesh(s:String,Mtls:Array=null) : Mesh
		{
			var i:int = 0;
			var j:int = 0;

			// ----- read data from string
			var D:Array = s.split("\n");	// data array
			var V:Vector.<Number> = new Vector.<Number>();		// array to contain vertices data
			var T:Vector.<Number> = new Vector.<Number>();		// array to contain texture coordinates data
			var N:Vector.<Number> = new Vector.<Number>();		// array to contain normals data
			var F:Array = [];			// array to contain triangle faces data
			var G:Array = [];			// groups array, containing submeshes faces
			var A:Array = [];			// temp array

			var n:uint = D.length;
			for (i=0; i<n; i++)
			{
				if (D[i].substr(0,2)=="v ")				// ----- if position definition
				{
					A = (D[i].substr(2)).split(" ");
					for (j=A.length-1; j>=0; j--)
						if (A[j]=="")	A.splice(j,1);
					for (j=0; j<A.length && j<3; j++)
						V.push(Number(A[j]));
				}
				else if (D[i].substr(0,3)=="vt ")		// ----- if vertex uv definition
				{
					A = (D[i].substr(2)).split(" ");
					for (j=A.length-1; j>=0; j--)
						if (A[j]=="")	A.splice(j,1);
					for (j=0; j<A.length && j<2; j++) 	// restrict to u,v instead of u,v,t
						T.push(Number(A[j]));
				}
				else if (D[i].substr(0,3)=="vn ")		// ----- if vertex normal definition
				{
					A = (D[i].substr(2)).split(" ");
					for (j=A.length-1; j>=0; j--)
					{
						//if (A[j].indexOf("e-")!=-1)
							//A[j]=A[j].split("e-")[0];
						if (A[j]=="")	A.splice(j,1);
					}
					for (j=0; j<A.length && j<3; j++)
						N.push(Number(A[j]));
				}
				else if (D[i].substr(0,2)=="f ")		// ----- if face definition
				{
					A = (D[i].substr(2)).split(" ");	// ["v/uv/n","v/uv/n","v/uv/n"]
					for (j=A.length-1; j>=0; j--)
						if (A[j]=="")
							A.splice(j,1);
						else
						{
							while (A[j].split("/").length<3)	A[j] = A[j]+"/-";
							A[j] = A[j].split("//").join("/-/");	// replace null values with "-"
							A[j] = A[j].split("/"); 	// format of f : [[v,uv,n],[v,uv,n],[v,uv,n]]
							if (A[j][2]=="-")	A[j][2]=A[j][0];	// default normal to vertex idx
						}
					F.push(A);
				}
				else if (D[i].substr(0,2)=="o ")		// ----- if object definition
				{
					G.push(F);
					F = [];
				}
				else if (D[i].substr(0,2)=="g ")		// ----- if group definition
				{
					G.push(F);
					F = [];
				}
				else if (D[i].substr(0,7)=="usemtl ")
				{
					F.push((D[i].substr(2)).split(" ")[1]);	// material id (defined in mtl file)
				}
			}//endfor

			G.push(F);

			//trace("var V:Array="+arrToStr(V));
			//trace("var T:Array="+arrToStr(T));
			//trace("var N:Array="+arrToStr(N));
			//trace("var F:Array="+arrToStr(F));

			var mmesh:Mesh = new Mesh();					// main mesh to add all submeshes into

			var mtl:BitmapData = null;						//
			if (Mtls!=null && Mtls.length>=2) mtl=Mtls[1];	// default material to use to first material

			for (var g:int=0; g<G.length; g++)
			{
				F = G[g];

				// ----- import faces data -----------------------------
				var verticesData:Vector.<Number> = new Vector.<Number>(); // to contain [vx,vy,vz,nx,ny,nz,u,v, ....]
				for (i=0; i<F.length; i++)
				{
					if (F[i] is String)	// switch to another material
					{
						if (Mtls!=null && Mtls.indexOf(F[i])!=-1)
							mtl = Mtls[Mtls.indexOf(F[i])+1];
					}
					else
					{
						var f:Array = F[i];		// data of a face: [[v,uv,n],[v,uv,n],[v,uv,n],...]

						for (j=0; j<f.length; j++)
						{
							var p:Array = f[j];	// data of a point:	[v,uv,n]
							for (var k:int=0; k<p.length; k++)
								p[k] = int(Number(p[k]))-1;
						}

						// ----- triangulate higher order polygons
						while (f.length>=3)
						{
							A = [];
							for (j=0; j<3; j++)
								A=A.concat(f[j]);
							// A: [v,uv,n,v,uv,n,v,uv,n]

							// ----- get vertices --------------------------------
							var vax:Number = V[A[0]*3+0];
							var vay:Number = V[A[0]*3+1];
							var vaz:Number = V[A[0]*3+2];
							var vbx:Number = V[A[3]*3+0];
							var vby:Number = V[A[3]*3+1];
							var vbz:Number = V[A[3]*3+2];
							var vcx:Number = V[A[6]*3+0];
							var vcy:Number = V[A[6]*3+1];
							var vcz:Number = V[A[6]*3+2];

							// ----- get normals ---------------------------------
							var px:Number = vbx - vax;
							var py:Number = vby - vay;
							var pz:Number = vbz - vaz;

							var qx:Number = vcx - vax;
							var qy:Number = vcy - vay;
							var qz:Number = vcz - vaz;
							// normal by determinant
							var nx:Number = py*qz-pz*qy;	//	unit normal x for the triangle
							var ny:Number = pz*qx-px*qz;	//	unit normal y for the triangle
							var nz:Number = px*qy-py*qx;	//	unit normal z for the triangle

							var nax:Number = nx;
							var nay:Number = ny;
							var naz:Number = nz;
							var nbx:Number = nx;
							var nby:Number = ny;
							var nbz:Number = nz;
							var ncx:Number = nx;
							var ncy:Number = ny;
							var ncz:Number = nz;
							if (N.length>0)
							{
								nax = N[A[2]*3+0];
								nay = N[A[2]*3+1];
								naz = N[A[2]*3+2];
								nbx = N[A[5]*3+0];
								nby = N[A[5]*3+1];
								nbz = N[A[5]*3+2];
								ncx = N[A[8]*3+0];
								ncy = N[A[8]*3+1];
								ncz = N[A[8]*3+2];
							}

							// ----- get UVs -------------------------------------
							var ua:Number = 0;
							var va:Number = 0;
							var ub:Number = 1;
							var vb:Number = 0;
							var uc:Number = 0;
							var vc:Number = 1;
							if (T.length>0)
							{
								ua = T[A[1]*2+0];
								va = 1-T[A[1]*2+1];
								ub = T[A[4]*2+0];
								vb = 1-T[A[4]*2+1];
								uc = T[A[7]*2+0];
								vc = 1-T[A[7]*2+1];
							}
							//while (ua<0) ua+=1; while (ua>1) ua-=1;
							//while (va<0) va+=1; while (va>1) va-=1;
							//while (ub<0) ub+=1; while (ub>1) ub-=1;
							//while (vb<0) vb+=1; while (vb>1) vb-=1;
							//while (uc<0) uc+=1; while (uc>1) uc-=1;
							//while (vc<0) vc+=1; while (vc>1) vc-=1;

							verticesData.push(	vax,vay,vaz, nax,nay,naz, ua,va,
												vbx,vby,vbz, nbx,nby,nbz, ub,vb,
												vcx,vcy,vcz, ncx,ncy,ncz, uc,vc);

							f.splice(1,1);
						}//endwhile
					}//endelse
				}//endfor i

				if (verticesData.length>0)
				{
					var cm:Mesh = new Mesh();
					cm.createGeometry(verticesData);
					cm.setTexture(mtl);	//
					cm.centerToGeometry();
					mmesh.addChild(cm);
				}
			}//endfor g

			if (mmesh.childMeshes.length==1)
				return mmesh.mergeTree();
			else
				return mmesh;	// returns mesh with submeshes in it
		}//endfunction

		/**
		* calls callback(L:Array) where array is [url,bmd,url,bmd,...] ,
		*/
		public static function parseMtlToArray(s:String,folder:String,callBackFn:Function) : Array
		{
			// ----- create an array of [id1,url1,id2,url2,...] ----------------
			var L:Array = [];
			var D:Array = s.split("\n");
			var tmp:* = null;
			for (var i:int=0; i<D.length; i++)
			{
				if (D[i].substr(0,7)=="newmtl ")
				{
					tmp = (D[i].substr(2)).split(" ");
					if (L.length%2==1) L.push(null);	// if prev id does not have mtl
					L.push(tmp[1]);
				}
				else if (D[i].substr(0,7)=="map_Kd ")
				{
					tmp = (D[i].substr(2)).split(" ");
					if (L.length%2==1) L.push(tmp[1]);	// ensure only one id to one mtl
				}
			}//endfor
			debugTrace("parseMtlToArray L="+L);

			// ----- loads sequentially each specified url ---------------------
			function loadImg(texF:String,folder:String,callBackFn:Function) : void
			{
				if (texF==null)
				{
					callBackFn(null);	// if no texture specified
					return;
				}

				var ldr:Loader = new Loader();
				function loadCompleteHandler(e:Event):void	{try{var bmp:Bitmap=(Bitmap)(ldr.content);} catch(e:Error) {callBackFn(null);} callBackFn(bmp.bitmapData); }
				function errorHandler(e:Event):void			{debugTrace("texture load Error occurred! e:"+e); callBackFn(null); }
				ldr.addEventListener(IOErrorEvent.IO_ERROR, errorHandler);
				ldr.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, errorHandler);
				ldr.contentLoaderInfo.addEventListener(Event.COMPLETE, loadCompleteHandler);
				try {ldr.load(new URLRequest(folder+texF));}	catch (error:Error)
				{debugTrace("texture load failed: Error has occurred."); callBackFn(null);}
			}//endfunction

			function loadNext(bmd:BitmapData) : void
			{
				L[i] = powOf2Size(bmd);
				i+=2;
				if (L.length<=i)
					callBackFn(L);
				else
					loadImg(L[i],folder,loadNext);
			}//endfunction

			i=1;
			loadImg(L[i],folder,loadNext);

			return L;
		}//endfunction

		/**
		* Loads obj file, exec fn after loading complete and passes back a Mesh
		*/
		public static function loadObj(url:String,fn:Function=null) : void
		{
			var folder:String = url.substr(0,url.length-url.split("/").pop().length);
			url = url.split("/").pop();
			debugTrace("loadObj("+url+","+folder+")");

			var s:String = "";		// the loaded boj format data
			var mesh:Mesh = null;	// the mesh to return

			// ----- loads the obj file first ------------------------------------------
			var ldr:URLLoader = new URLLoader();
			try {ldr.load(new URLRequest(folder+url));}	catch (error:SecurityError)
			{debugTrace("obj load failed: SecurityError has occurred.");}
			ldr.addEventListener(IOErrorEvent.IO_ERROR, function(e:Event):void {debugTrace("obj load IO Error occurred! e:"+e);});
			ldr.addEventListener(Event.COMPLETE, function (e:Event):void
			{
				// ----- splits obj into groups and parse each individual group
				s = ldr.data;
				var S:Array = s.split("mtllib ");
				if (S.length==1)	// no material specified
				{
					fn(parseObjToMesh(s));
				}
				else
				{
					var mtl:String = S[1].split("\n")[0];
					var mtlldr:URLLoader = new URLLoader();
					try {mtlldr.load(new URLRequest(folder+mtl));}	catch (e:Error)
					{debugTrace("mtl load failed: "+e);}
					function loadCompleteHandler(e:Event):void
					{
						parseMtlToArray(mtlldr.data,folder,function(T:Array):void {fn(parseObjToMesh(s,T));});
					}
					mtlldr.addEventListener(IOErrorEvent.IO_ERROR, function(e:Event):void {debugTrace("mtl load IO Error occurred! e:"+e);});
					mtlldr.addEventListener(Event.COMPLETE, loadCompleteHandler);
				}
			});
		}//endfunction

		/**
		* save this mesh tree data to raw mesh file format
		*/
		public function saveAsRmf(fileName:String="data") : void
		{
			var ba:ByteArray = toByteArray();
			var MyFile:FileReference = new FileReference();
			MyFile.save(ba,fileName+".rmf");
		}//endfunction

		/**
		* write this mesh tree to byteArray for writing to file
		*/
		public function toByteArray(ba:ByteArray=null) : ByteArray
		{
			// ----- write mesh data to byteArray
			if (ba==null)
			{
				ba = new ByteArray();
				ba.endian = "littleEndian";
			}

			// ----- type of mesh data
			ba.writeInt(dataType);

			// ----- write vertex data
			var n:int=0;
			if (vertData!=null) n=vertData.length;	// length of vertex data
			ba.writeInt(n);
			var vD:Vector.<Number> = vertData;
			if (dataType==_typeV && vD!=null)
			{
				// ----- apply current transform to mesh if typeV
				if (transform==null) transform = new Matrix4x4();
				var T:Matrix4x4 = transform;

				vD = new Vector.<Number>();
				for (var j:int=0; j<n;)
				{
					var vx:Number = vertData[j++];
					var vy:Number = vertData[j++];
					var vz:Number = vertData[j++];
					var nx:Number = vertData[j++];
					var ny:Number = vertData[j++];
					var nz:Number = vertData[j++];
					var tx:Number = vertData[j++];
					var ty:Number = vertData[j++];
					var tz:Number = vertData[j++];
					var nvx:Number = T.aa*vx+T.ab*vy+T.ac*vz+T.ad;
					var nvy:Number = T.ba*vx+T.bb*vy+T.bc*vz+T.bd;
					var nvz:Number = T.ca*vx+T.cb*vy+T.cc*vz+T.cd;
					var nnx:Number = T.aa*nx+T.ab*ny+T.ac*nz;
					var nny:Number = T.ba*nx+T.bb*ny+T.bc*nz;
					var nnz:Number = T.ca*nx+T.cb*ny+T.cc*nz;
					var ntx:Number = T.aa*tx+T.ab*ty+T.ac*tz;
					var nty:Number = T.ba*tx+T.bb*ty+T.bc*tz;
					var ntz:Number = T.ca*tx+T.cb*ty+T.cc*tz;
					var nnl:Number = Math.sqrt(nnx*nnx+nny*nny+nnz*nnz);
					nnx/=nnl; nny/=nnl; nnz/=nnl;
					var ntl:Number = Math.sqrt(ntx*ntx+nty*nty+ntz*ntz);
					ntx/=ntl; nty/=ntl; ntz/=ntl;
					vD.push(nvx,nvy,nvz,nnx,nny,nnz,ntx,nty,ntz,vertData[j++],vertData[j++]);
				}//endfor
			}//endif
			for (var i:int=0; i<n; i++)	ba.writeFloat(vD[i]);

			// ----- write index data
			n=0;
			if (idxsData!=null) n=idxsData.length;	// length of index data
			ba.writeInt(n);
			for (i=0; i<n; i++)	ba.writeShort(idxsData[i]);

			// ----- write child meshes data
			n=childMeshes.length;
			ba.writeInt(n)
			for (i=0; i<n; i++)
				childMeshes[i].toByteArray(ba);
			return ba;
		}//endfunction

		/**
		* read raw mesh data from given byteArray and returns new mesh
		*/
		public static function parseRmfToMesh(ba:ByteArray) : Mesh
		{
			var cstk:Vector.<int> = new Vector.<int>();		// containing sibling counts
			var pstk:Vector.<Mesh> = new Vector.<Mesh>();	// containing parents meshes

			ba.endian = "littleEndian";
			ba.position = 0;

			do {
				var type:int = ba.readInt();
				var i:int=0;

				var vl:int = ba.readInt();	// verticesData length
				var verticesData:Vector.<Number> = new Vector.<Number>();
				for (i=0; i<vl; i++)	verticesData.push(ba.readFloat());
				var il:int = ba.readInt();	// indicesData length
				var indicesData:Vector.<uint> = new Vector.<uint>();
				for (i=0; i<il; i++)	indicesData.push(ba.readShort());

				var m:Mesh = new Mesh();
				if (verticesData.length>0 && indicesData.length>0)
				{
					m.vertData = verticesData;
					m.idxsData = indicesData;
					m.dataType = type;
					m.trisCnt = il/3;	// number of tris to render
					m.collisionGeom = new CollisionGeometry(verticesData,indicesData);
				}

				if (pstk.length>0)			// add this mesh to parent
				{
					pstk[pstk.length-1].addChild(m);
					cstk[cstk.length-1]--;
				}

				var n:int = ba.readInt();	// number of child meshes
				if (n>0)			// if have children
				{
					pstk.push(m);	// set this as parent
					cstk.push(n);	// set child meshes to parse
				}
				else	// if done parsing siblings
					while (cstk.length>0 && cstk[cstk.length-1]<=0)
					{
						cstk.pop();
						m=pstk.pop();
					}
			} while (pstk.length > 0);

			return m;
		}//endfunction

		/**
		* parses raw mesh geometry data from given file url
		*/
		public static function loadRmf(url:String,fn:Function=null) : void
		{
			var ldr:URLLoader = new URLLoader();
			ldr.dataFormat = "binary";
			var req:URLRequest = new URLRequest(url);
			function completeHandler(e:Event):void
			{
				if (fn!=null)	fn(parseRmfToMesh(ldr.data));
			}
			ldr.addEventListener(Event.COMPLETE, completeHandler);
			ldr.load(req);
		}//endfunction

		/**
		* returns a new bitmapData with width,height to power of 2 or original, if already power of 2
		*/
		public static function powOf2Size(bmd:BitmapData) : BitmapData
		{
			if (bmd==null) return null;

			var w:uint = bmd.width;
			var h:uint = bmd.height;

			var val:uint = 1;
			while (val*2<=w) val*=2;
			w = val;

			val = 1;
			while (val*2<=h) val*=2;
			h = val;

			if (w!=bmd.width || h!=bmd.height)
			{
				var nbmd:BitmapData = new BitmapData(w,h,bmd.transparent,0x00000000);
				nbmd.draw(bmd,new Matrix(w/bmd.width,0,0,h/bmd.height,0,0));
				return nbmd;
			}
			else
				return bmd;
		}//endfunction

		/**
		* creates a fps counter readout textfield that finds average of time taken in n frames
		*/
		public static function createFPSReadout() : TextField
		{
			var tf:TextField = new TextField();
			tf.defaultTextFormat = new TextFormat("_sans",12,0x00ffFF);
			tf.autoSize = "left";
			tf.wordWrap = false;
			tf.selectable = false;
			tf.mouseEnabled = false;
			function enterFrameHandler(ev:Event):void {tf.text = fpsStats;}//endfunction
			tf.addEventListener(Event.ENTER_FRAME,enterFrameHandler);
			enterFrameHandler(null);
			return tf;
		}//endfunction

		/**
		* appends given string to debugTf textField
		*/
		public static function debugTrace(s:String) : void
		{
			if (debugTf==null)
			{
				debugTf = new TextField();	// static ref
				debugTf.x = 5;
				debugTf.y = 5;
				debugTf.defaultTextFormat = new TextFormat("_sans",10,0x00ff00);
				debugTf.autoSize = "left";
				debugTf.multiline = true;
				debugTf.wordWrap = false;
			}
			debugTf.appendText(s+"\n");
		}//endfunction

		/**
		* Standard vertex shader read src 			(3 instructions)
		* input : 		va0 = vertex	va1 = normal	va2 = tangent	va3 = texU,texV
		* outputs:		vt0 = vertex	vt1 = normal  	vt2 = texU,texV vt3 = tangent
		*/
		private static function _stdReadVertSrc(hasLights:Boolean=true,hasNorm:Boolean=false) : String
		{
			var s:String = "mov vt0, va0\n" + "mov vt2, va3\n";
			if (hasLights)
			{
				s += "mov vt1, va1\n";
				if (hasNorm) s += "mov vt3, va2\n";
			}
			return s;
		}//endfunction

		/**
		* Batch rendering particles Vertex Shader Code		(36 instructions)
		* inputs:		va0 = vx,vy,vz	 					// position for this vertex
		*				va1 = texU,texV,idx					// vertex UV and transform idx
		* constants:	vc0=[nearClip,farClip,focalL,aspectRatio], vc1-vc4=TransformMatrix
		*				vc5 = 0,1,2,n						// useful constants, n=num of rows or cols
		* 				vc6 = lx,ly,lz,0.001			 	// look at point
		*				vc7 = tx,ty,tz,idx+scale			// translation
		*				...
		*				vci = tx,ty,tz,idx+scale			// translation
		* outputs:		vt0 = vx,vy,vz,1	vertex
		*				vt2 = texU,texV
		*/
		private static function _particlesVertSrc() : String
		{
			var s:String =
			"mov vt2, va1\n" +							// vt2 = texU,texV,idx,0
			"mov vt7, vc[vt2.z]\n" + 					// vt7 = tx,ty,tz,idx+scale

			// ----- derive true UV from idx
			"frc vt1.w, vt7.w\n" +						// vt1.w = scale

			"sub vt1.z, vt7.w, vt1.w\n" + 				// vt1.zw = idx,scale
			"add vt1.z, vt1.z, vc6.w\n" +				// vt1.z = idx+0.001 to solve the rounding error
			"div vt1.x, vt1.z, vc5.w\n" +				// vt1.xzw = idx/n,idx,scale
			"frc vt1.y, vt1.x\n" +						// vt1.xyzw = idx/n,rem(idx/n)==col/n,idx,scale
			"sub vt1.x, vt1.x, vt1.y\n" + 				// vt1.xyzw = row,col/n,idx,scale
			"div vt1.x, vt1.x, vc5.w\n" +				// vt1.xyzw = row/n,col/n,idx,scale

			"add vt2.xy, vt2.xy, vt1.yx\n" +			// vt2.xy = true texU,texV

			"mov vt7.w, vt1.w\n" + 						// vt7 = tx,ty,tz,scale

			"mov vt1, vc6\n" +							// vt1 = lx,ly,lz	look at point
			"sub vt1, vt1, vt7\n" +						// vt1 = lx-tx,ly-ty,lz-tz	vector to point
			"nrm vt1.xyz, vt1\n" + 						// vt1 = (lx-tx,ly-ty,lz-tz)  normalized
			"mov vt4, vc5.xxyx\n" +						// vt4 = 0,0,1,0	dir vector
			"crs vt3.xyz, vt4, vt1\n" +					// vt3.xyz = rot axis
			"nrm vt3.xyz, vt3.xyz\n" +					// vt3.xyz = rot axis normalized

			"dp3 vt3.w, vt4, vt1\n" + 					// vt3.w = cosA

			// ----- using half angle formula calculate sin(A/2) cos(A/2)
			"sub vt1.x, vc5.y, vt3.w\n" +				// vt1.x = 1-cosA
			"add vt1.y, vc5.y, vt3.w\n" +				// vt1.xy = 1-cosA,1+cosA
			"div vt1.xy, vt1.xy, vc5.zz\n" +			// vt1.xy = (1-cosA)/2,(1+cosA)/2
			"sqt vt1.xy, vt1.xy\n" + 					// vt1.xy = sqrt((1-cosA)/2),sqrt((1+cosA)/2) = sin(A/2),cos(A/2)
			"mul vt3.xyz, vt3.xyz, vt1.xxx\n" + 		//
			"mov vt3.w, vt1.y\n" +						// vt3.xyzw = (qx,qy,qz,w)	quaternion

			"mov vt4, va0\n" +							// vt4 = vx,vy,vz untransformed
			"mov vt4.w, vc5.x\n"+						// vt4 = vx,vy,vz,0 untransformed
			_quatRotVertSrc() + 						// vt4 = quat rotate vt4
			"mul vt4.xyz, vt4.xyz, vt7.www\n" +			// vt4.xyz = scale*(vx,vy,vz)
			"add vt0.xyz, vt4.xyz, vt7.xyz\n" +			// vt0.xyz = (vx,vy,vz) translated rotated point

			//"add vt0.xyz, va0.xyz, vc[vt2.z].xyz\n" +	// TEST

			"mov vt0.w, vc5.y\n";						// vt0 = vx,vy,vz,1	vertex val
			return s;
		}//endfunction

		/**
		* Batch meshes rendering Vertex Shader Code
		* inputs:		va0 = vx,vy,vz			//	vertex data
		*				va1 = nx,ny,nz			//	normal data
		*				va2 = tx,ty,tz			//	tangent data
		*				va3 = texU,texV,i,i+1	//	UV data + constants index
		* constants:	vc[i] = qx,qy,qz,sc, 	// orientation quaternion
		*				vc[i+1] = tx,ty,tz,0	// translation
		* outputs:		vt0 = vertex	vt1 = normal  	vt2 = texU,texV		vt3 = tangent
		*/
		private static function _meshesVertSrc(hasLights:Boolean=true,hasNorm:Boolean=false) : String
		{
			var s:String =
			"mov vt0.xyzw, vc4.xyzw\n"+				// vt0 = 0,0,0,1
			"mov vt2, va3\n"+						// vt2 = texU,texV,idx,idx+1

			// ----- orientate vertex
			"mov vt3, vc[vt2.z]\n"+					// vt3 = qx,qy,qz,sc quaternion axis component + obj scale
			"mov vt4, va0\n"+						// vt4.xyz = vx,vy,vz	vertex to transform
			"mul vt4.xyz, vt4.xyz, vt3.www\n"+		// vt4.xyz = vx*sc,vy*sc,vz*sc
			"dp3 vt3.w, vt3.xyz, vt3.xyz\n"+		// vt3.w = xx+yy+zz
			"sub vt3.w, vt0.w, vt3.w\n"+			// vt3.w = 1-xx-yy-zz
			"sqt vt3.w, vt3.w\n"+					// vt3.w = sqrt(1-xx-yy-zz) quat real component
			"mov vt7, vt3\n"+						// vt7 = qx,qy,qz,w	quaternion copy
			_quatRotVertSrc()+						// vt4.xyz = rotated vx,vy,vz
			"add vt0.xyz, vt4.xyz, vc[vt2.w].xyz\n";// vt0 = nvx,nvy,nvz,1 rotated translated vertex

			// ----- orientate normal
			if (hasLights)
			{
				s+=
				"mov vt3, vt7\n"+					// vt3 = qx,qy,qz,a quaternion
				"mov vt4, va1\n"+					// vt4.xyz = nx,ny,nz	normal to rotate
				_quatRotVertSrc()+					// vt4.xyz=rotated nx,ny,nz
				"mov vt1, vt4\n"+					// vt1 = nnx,nny,nnz rotated normal
				"mov vt1.w, vc4.x\n";				// vt1 = nnx,nny,nnz,0 rotated normal
				if (hasNorm)
				s+=
				"mov vt3, vt7\n"+					// vt3 = qx,qy,qz,a quaternion
				"mov vt4, va2\n"+					// vt4.xyz = tx,ty,tz	tangent to rotate
				"mov vt4.w, vc4.x\n"+				//
				_quatRotVertSrc()+					// vt4.xyz = rotated tx,ty,tz
				"mov vt3, vt4\n"+					// vt3.xyz = rotated tx,ty,tz
				"mov vt3.w, vc4.x\n";				// vt3 = nnx,nny,nnz,0 rotated normal
			}
			return s;
		}//endfunction

		/**
		* MD5 GPU Skinning! Vertex Shader Code		(159 instructions)
		* inputs:		va0 = texU,texV	 					// UV for this point
		*				va1 = wnx,wny,wnz,transIdx 			// weight normal 1
		* 				va2 = wtx,wty,wtz,0		 			// weight tangent 1
		*				va3 = wvx,wvy,wvz,transIdx+weight 	// weight vertex 1
		*				va4 = wvx,wvy,wvz,transIdx+weight  	// weight vertex 2
		*				va5 = wvx,wvy,wvz,transIdx+weight  	// weight vertex 3
		*				va6 = wvx,wvy,wvz,transIdx+weight 	// weight vertex 4
		* constants:	vc[i] = qx,qy,qz,0, 	// orientation quaternion
		*				vc[i+1] = tx,ty,tz,0	// translation
		* outputs:		vt0 = vertex  vt1 = normal  vt2 = texU,texV
		*/
		private static function _skinningVertSrc(hasLights:Boolean=true) : String
		{
			var s:String =
			"mov vt2, va0\n"+						// vt2.xy = texU,texV
			"mov vt0, vc4\n";						// vt0 = 0,0,0,1

			// ----- calculate vertex from weights --------
			for (var i:int=3; i<7; i++)	// loop 4 x 28 = 112 instrs
			{
				s+=
				"frc vt7.y,	va"+i+".w\n"+				// vt7.y = weight
				"sub vt2.w, va"+i+".w, vt7.y\n"+		// vt2.w = transIdx

				"mov vt3, vc[vt2.w]\n"+					// vt3 = orientation quaternion
				"dp3 vt3.w, vt3.xyz, vt3.xyz\n"+		// vt3.w = xx+yy+zz
				"sub vt3.w, vt0.w, vt3.w\n"+			// vt3.w = 1-xx-yy-zz
				"sqt vt3.w, vt3.w\n"+					// vt3.w = sqrt(1-xx-yy-zz) quat real component

				"mov vt4.xyz, va"+i+".xyz\n"+			// vt4.xyz = wvx,wvy,wvz
				"mov vt4.w, vc4.x\n"+					// vt4.xyzw = wvx,wvy,wvz,0
				_quatRotVertSrc()+						// vt4.xyz=rotated wvx,wvy,wvz
				"add vt4.xyz, vt4.xyz, vc[vt2.w+1]\n"+	// vt4.xyz=rotated translated wvx,wvy,wvz
				"mul vt4.xyz, vt4.xyz, vt7.yyy\n"+		// vt4.xyz=weighted transformed wvx,wvy,wvz

				"add vt0.xyz, vt0.xyz, vt4.xyz\n";		// vt0 = accu vertex val
			}

			// ----- calculate normal and tangent -----------------------------
			if (hasLights)				// 45 instrs
			{
				s+=
				"mov vt4, va1\n"+					// vt4.xyzw = wnx,wny,wnz,transIdx
				"mov vt3, vc[vt4.w]\n"+				// vt3 = orientation quaternion for normal
				"dp3 vt3.w, vt3.xyz, vt3.xyz\n"+	// vt3.w = xx+yy+zz
				"sub vt3.w, vt0.w, vt3.w\n"+		// vt3.w = 1-xx-yy-zz
				"sqt vt3.w, vt3.w\n" +				// vt3.w = sqrt(1-xx-yy-zz) quat real component
				"mov vt7, vt3\n" +					// vt7 = copy of quaternion
				"mov vt4.w, vc4.x\n"+				// vt4.xyzw = wnx,wny,wnz,0
				_quatRotVertSrc()+					// vt6.xyz = rotated wnx,wny,wnz
				"nrm vt1.xyz, vt4.xyz\n"+			// vt1=normalized nx,ny,nz

				"mov vt3, vt7\n" + 					// vt3 = quaternion
				"mov vt4, va2\n" +					// vt4.xyzw = wtx,wty,wtz,0
				_quatRotVertSrc() +					// vt6.xyz = rotated wtx,wty,wtz
				"nrm vt3.xyz, vt4.xyz\n";			// vt1=normalized tx,ty,tz
			}
			return s;
		}//endfunction

		/**
		* Quaternion rotation (17 instructions)
		* inputs:	vt3=ux,uy,uz,a	// rotation quaternion
		*			vt4=px,py,pz,0	// point to rotate
		* output:	vt4.xyz=rotated point
		* 			vt6.xyz=quatMul vt3 vt4
		*/
		private static function _quatRotVertSrc() : String
		{
			var s:String =
			_quatMulVertSrc(3,4, 6, 5)+	// vt6 = quatMul vt3 vt4
			"neg vt3.xyz, vt3.xyz\n"+	// vt3 = -ux,-uy,-uz,a
			_quatMulVertSrc(6, 3, 4, 5);
			return s;
		}//endfunction

		/**
		* Quaternion multiplication (8 instructions)
		* inputs:  	vti0=ux,uy,uz,a	// a,b,c are the real components
		*			vti1=vx,vy,vz,b
		* output:	vto0=wx,wy,wz,c	// multiplication result
		* 			vti0=ux,uy,uz,a	// unchanged from input!
		*/
		private static function _quatMulVertSrc(i0:uint,i1:uint,o0:uint,w0:uint) : String
		{
			// quarternion multiplication : (a+U)(b+V) = (ab - U.V) + (aV + bU + UxV)
			var s:String =
			"crs vt"+w0+".xyz, vt"+i0+".xyz, vt"+i1+".xyz\n"+	// vtw0.xyz = UxV
			"dp3 vt"+w0+".w, vt"+i0+".xyz, vt"+i1+".xyz\n"+		// vtw0.w = U.V
			"mul vt"+o0+".w, vt"+i0+".w, vt"+i1+".w\n"+			// vto0.w = ab
			"sub vt"+o0+".w, vt"+o0+".w, vt"+w0+".w\n"+			// vto0.w = ab-U.V
			"mul vt"+o0+".xyz, vt"+i1+".xyz, vt"+i0+".www\n"+	// vto0.xyz = aV
			"add vt"+o0+".xyz, vt"+o0+".xyz, vt"+w0+".xyz\n"+	// vto0.xyz = aV + UxV
			"mul vt"+w0+".xyz, vt"+i0+".xyz, vt"+i1+".www\n"+	// vtw0.xyz = bU
			"add vt"+o0+".xyz, vt"+o0+".xyz, vt"+w0+".xyz\n";	// vto0.xyz = aV + UxV + bU
			return s;
		}//endfunction

		/**
		* Standard vertex shader perspective render src (19 instructions max)
		* inputs: 		vt0 = vx,vy,vz,1 untransformed vertex
		*				vt1 = nx,ny,nz,0 untransformed nomal
		*				vt2 = texU,texV
		*				vt3 = tx,ty,tz,0 untransformed tangent
		* constants:	vc0=[nearClip,farClip,focalL,aspectRatio], vc1-vc4=TransformMatrix
		* frag outputs:	v0= transformed vertex
		*				v1= transformed normal
		*				v2= UV
		*				v4= transformed tangent
		*/
		private static function _stdPersVertSrc(hasLights:Boolean=true,hasFog:Boolean=true,hasNorm:Boolean=false) : String
		{
			var s:String = "m34 vt0.xyz, vt0, vc1\n";		// vt0 = apply spatial transform to vertex

			if (hasLights || hasFog) s+= "mov v0, vt0\n";	// move vertex to fragment shader v0

			s+="mul vt0.y, vt0.y, vc0.w\n" + 	// vt0.y = vt0.y*aspect ratio
			"mul vt0.xy, vt0.xy, vc0.zz\n"+		// vt0.xy = x*focalL/nearClip,y*focalL/nearClip
			"div vt0.xyw, vt0.xyz, vc0.xxx\n" +	// vt0.w = z/nearClip (homogeneous coordinate)
			"mov vt0.z, vc4.w\n" + 				// vt0.z = 1
			// vt0.xyz will be automatically divided by vt0.w	depth buffer test (greater)

			"mov op, vt0\n" +	 				// output transformed point
			"mov v2, vt2\n";					// move UV to fragment shader v2

			if (hasLights)
			{
			s+=	"mov vt1.w, vc4.x\n" +			// vt1 = nx,ny,nz,0
				"m33 vt1.xyz, vt1.xyz, vc1\n" +	// vt1=transformed normal
				"nrm vt1.xyz, vt1.xyz\n" + 		// vt1=normalized normals
				"mov v1, vt1\n";				// move normal to fragment shader v1
			if (hasNorm)
			s+=	"mov vt3.w, vc4.x\n" +			// vt3 = nx,ny,nz,0
				"m33 vt3.xyz, vt3.xyz, vc1\n" +	// vt3=transformed tangent
				"nrm vt3.xyz, vt3.xyz\n" + 		// vt3=normalized tangent
				"mov v4, vt3\n";				// move tangent to fragment shader v4
			}
			return s;
		}//endfunction

		/**
		* calculate point lights illuminated pixel color
		* inputs:		v0= transformed vertex
		*				v1= transformed normal
		*				v2= UV
		*				v4= transformed tangent
		* constants:	fc0= [0,0.5,1,2]	// 0,0.5,1,2
		*				fc1= [r,g,b,0]		// ambient rgb
		*				fc2= [st,h1,h0,0]	// specStr,hardness+1,hardness
		*				fc3= [r,g,b,fogD]	// linear fog factor
		*				fc4= [px,py,pz,1]	// light 1 point
		*				fc5= [r,g,b,1]		// light 1 color
		*				...
		*				fc_n*2+4= [px,py,pz,0]		// light n position
		*				fc_n*2+5= [r,g,b,1]			// light n color,
		*/
		private static function _stdFragSrc(numLights:uint,hasTex:Boolean,useMip:Boolean,hasNorm:Boolean,hasSpec:Boolean,fog:Boolean,envMap:Boolean,shadowMap:Boolean) : String
		{
			var s:String = "";
			var mip:String = "mipnone";
			if (useMip) mip = "miplinear";

			// ----- frag shader optimization test --------------------------------------
			if (numLights==0)
			{
				if (hasTex)
					s = "tex ft0, v2, fs0 <2d,linear,"+mip+",repeat> \n" + 	// sample tex "tex ft0, v2, fs0 <2d,nearest,repeat> \n" + // sample tex
						"mul ft0.xyz, ft0.xyz, fc1.xyz\n"; 			// mult ambient color


				else
					s = "mov ft0.a, fc0.z\n" + 						// alpha = 1
						"mov ft0.xyz, fc1.xyz\n"; 					// set as ambient color

				if (fog)
				{
					s +="div ft6, v0.zzzz, fc3.wwww\n"+		// ft6 = z/fogD,z/fogD,z/fogD,z/fogD
						"sat ft6, ft6\n"+					//
						"sub ft7, fc0.zzzz, ft6\n"+			// ft7 = 1-z/fogD,1-z/fogD,1-z/fogD,1-z/fogD
						"mul ft6.xyz, ft6.xyz, fc3.xyz\n"+	// ft6 = fog vals fraction
						"mul ft7.xyz, ft7.xyz, ft0.xyz\n"+	// ft7 = color vals fraction
						"add oc, ft7, ft6\n";				// output
				}
				else
					s+="mov oc, ft0\n";							// output
				return s;
			}

			// ----- upload lightpoints info ----------------------------------
			if (hasTex)
				s =	"tex ft0, v2, fs0 <2d,linear,"+mip+",repeat> \n"; 	// ft0=sample texture with UV use miplinear to enable mipmapping
			else
				s = "mov ft0, fc0.zzzz\n";				// ft0 = 1,1,1,1

			if (hasNorm)	// if has normal mapping
			s +="tex ft7, v2, fs1 <2d,linear,"+mip+",repeat>\n" +	// ft7=sample normMap with UV
				"mul ft7.xyz, ft7.xyz, fc0.www\n"+			// ft7.xyz *= 2
				"sub ft7.xyz, ft7.xyz, fc0.zzz\n"+			// ft7.xyz = ft7.xyz*2-1
				"crs ft3.xyz, v1.xyz, v4.xyz\n"+			// ft3=co tangent y
				"mul ft2.xyz, v4.xyz, ft7.xxx\n"+			// ft2=x*tangent
				"mul ft3.xyz, ft3.xyz, ft7.yyy\n"+			// ft3=y*co tangent
				"mul ft1.xyz, v1.xyz, ft7.zzz\n"+			// ft1=z*normal
				"add ft1.xyz, ft1.xyz, ft2.xyz\n"+
				"add ft1.xyz, ft1.xyz, ft3.xyz\n"+			// ft1=perturbed normal
				"nrm ft1.xyz, ft1.xyz\n";
			else
			s +="nrm ft1.xyz, v1.xyz\n";			// normalized vertex normal

			// ----- for each light point, op codes to handle lighting mix ----
			for (var i:int=0; i<numLights; i++)
			{
				s+= "sub ft2, fc"+(i*2+4)+", v0 \n"+	// ft2=vector from point to light source
					"nrm ft2.xyz, ft2.xyz \n";			// ft2=normalize light vector

					// ----- calculate diffuse lighting
				s+=	"dp3 ft3, ft2, ft1.xyz\n"+			// ft3.xyzw=dot normal with light vector
					"max ft3, ft3, fc0.xxxx\n"+	  		// ft3=max(0,ft3)
					"mul ft3, ft0, ft3\n"+  			// ft3=multiply fragment color by intensity from texture
					"mul ft3, ft3, fc"+(i*2+5)+"\n"+	// ft3=multiply fragment color by light color

					// ----- calculate phong lighting
					"nrm ft4.xyz, v0.xyz\n" +			// ft4 = normalized vector to point
					"dp3 ft4.w, ft4.xyz, ft1.xyz\n" + 	// ft4.w = ptVector . normal
					"add ft4.w, ft4.w, ft4.w\n" +		// ft4.w = 2*(ptVector . normal)
					"mul ft7.xyz, ft1.xyz, ft4.www\n" + // ft5.xyz = 2(ptVector . normal)normal
					"sub ft4.xyz, ft4.xyz, ft7.xyz\n" + // ft4.xyz = reflected vector to point
					"dp3 ft4.xyz, ft4.xyz, ft2.xyz\n";	// ft4=magnitude of specular

					// ----- calculate specular reflection
				s+= "mul ft7.z, ft4.x, fc2.y\n"+		// ft7.z=mag*hardness1
					"sub ft7.z, ft7.z, fc2.z\n"+		// ft7.z=mag*hardness1 - hardness0
					"max ft7.z, ft7.z, fc0.xxxx\n"+		// ft7.z=max(brightness,0)
					"mul ft7.z, ft7.z, fc2.x\n"+		// ft7.z=brightness*sf
					"mul ft2, fc"+(i*2+5)+", ft7.zzzz\n";	// ft2 = spec light color*sf

				if (shadowMap)
				//s+=_cubeSoftShadowFragSrc(i,numLights)+	// uses ft7 output to ft4
				s+= _cubeShadowFragSrc(i,numLights)+	// uses ft7 output to ft4
					"mul ft3, ft3, ft4\n"+				// set diff to 0 if under shadows
					"mul ft2, ft2, ft4\n";				// set spec to 0 if under shadows

				if (i==0)
					s +="mov ft5, ft3\n"+					// ft5=diffuse lighting accu
						"mov ft6, ft2\n";					// ft6=specular highlights accu
				else
					s+= "max ft5, ft5, ft3 \n"+				// ft5=accumulated diffuse color
						"add ft6, ft6, ft2 \n";				// ft6=accumulated specular highlight
			}//endfor


			if (envMap)
			s += _envMapFragSrc()+						// uses ft7 output to ft4
				"max ft6, ft6, ft4\n";					// include environment map

			if (hasSpec)
			s+=	"tex ft7, v2, fs2 <2d,linear,"+mip+",repeat>\n"+	// ft7=sample SpecMap with UV
				"mul ft6, ft6, ft7\n";					// normMapspecFactor*light color*sf

			s+= "add ft5, ft5, ft6\n"+					// combine specular highlight with diffuse color
				"mov ft5.w, ft0.w\n"+					// move alpha value of texture over
				"mul ft1.rgb, ft0.rgb, fc1.rgb\n";		// ft1= calculated ambient color

			// ----- implement simple linear fog ------------------------------
			if (fog)
			s+=	"max ft1, ft1, ft5\n"+				// add ambient color with illum color
				"div ft6, v0.zzzz, fc3.wwww\n"+		// ft6 = z/fogD,z/fogD,z/fogD,z/fogD
				"sat ft6, ft6\n"+					//
				"sub ft7, fc0.zzzz, ft6\n"+			// ft7 = 1-z/fogD,1-z/fogD,1-z/fogD,1-z/fogD
				"mul ft6.w, ft6.w, ft1.w\n"+		// ft6 = z/fogD,z/fogD,z/fogD,alpha*z/fogD
				"mul ft6.xyz, ft6.xyz, fc3.xyz\n"+	// ft6 = fog vals fraction
				"mul ft7, ft7, ft1\n"+				// ft7 = color vals fraction
				"add oc, ft7, ft6\n";
			else
			s+=	"max oc, ft1, ft5\n";				// light and output the color

			return s;
		}//endfunction

		/**
		* environment mapping with cube map		(7 instrs)
		* outputs:	 ft4 = env map colors
		*/
		private static function _envMapFragSrc() : String
		{
			var s:String =
			"nrm ft7.xyz, v1\n"+				// normalized normal

			// ----- calculate reflection vector
			"dp3 ft4, v0.xyz, ft7.xyz\n"+		// ft4=dot normal with incidence vector
			"mul ft3.xyz, ft4.xxx, ft7.xyz\n"+	// ft3=view vector projection onto normal (v.n)v
			"sub ft4.xyz, v0.xyz, ft3.xyz\n"+
			"sub ft4.xyz, ft4.xyz, ft3.xyz\n"+	// ft4=reflected vector
			//"nrm ft4.xyz, ft4.xyz\n"+			// normalized reflected vector
			"tex ft4, ft4.xyz, fs3 <cube,linear> \n"+ 	// fs1=environment map
			"mul ft4, ft4, fc2.xxxx\n";			// multiply by specular factor
			return s;
		}//endfunction

		/**
		* references shadow map texture when calculating illuminated pixel color
		* inputs:		v0= transformed vertex
		*				v1= transformed normal
		*				v2= UV
		*				v4=[nearClip,farClip,focalL,aspectRatio]
		* constants:	fc0= [0,0.5,1,2]	// useful constants
		*				fc1= [r,g,b,sf]		// ambient and specular factor
		*				fc2= [r,g,b,fogD]	// linear fog factor
		*				...
		*				fc_i*2+4= [px,py,pz,bias]	// light n point
		*				fc_i*2+5= [r,g,b,1]			// light n color
		*				fc_n*2+4= [64*64,64,1,1/64]	// useful constants
		* output: 		ft4= 1 or 0
		*/
		private static function _cubeSoftShadowFragSrc(idx:uint,numLights:uint) : String
		{
			var s:String =
				"sub ft7.xyz, v0.xyz,  fc"+(idx*2+4)+".xyz\n"+		// ft7= position relative to light POV
				"dp3 ft7.w, ft7.xyz, ft7.xyz\n"+					// ft7.w = dist squared from light src

				// ----- perspective correction bias
				"mov ft4.xyz, fc"+(idx*2+4)+".xyz\n"+
				"neg ft4.xyz, ft4.xyz\n"+							// ft4.xyz = cam posn from light POV
				"dp3 ft4.w, ft4.xyz, ft4.xyz\n"+					//
				"sqt ft4.w, ft4.w\n"+								// ft4.w = dist to cam from light
				"div ft4.xyz, ft4.xyz, ft4.www\n"+					// ft4.xyz = unit vector to cam from light
				"dp3 ft4.w, ft4.xyz, ft7.xyz\n"+					// ft4.w = proj dist onto unit camV
				"mul ft4.xyz, ft4.xyz, ft4.www\n"+					// ft4.xyz =
				"sub ft4.xyz, ft7.xyz, ft4.xyz\n"+					// ft4.xyz = perpendicular vector to posn
				"div ft4.w, ft4.w, ft7.w\n"+						// ft4.w = cosAng
				"mul ft4.w, ft4.w, fc"+(idx*2+4)+".w\n"+			// ft4.w from -bias to bias
				"add ft4.w, ft4.w, fc"+(idx*2+4)+".w\n"+			// ft4.w from 0 to 2bias
				"sub ft4.w, ft4.w, fc"+(idx*2+5)+".w\n"+			//
				"mul ft4.xyz, ft4.xyz, ft4.www\n"+					// ft4.xyz = adjusted perpendicular vector from camV to vertex
				"add ft7.xyz, ft7.xyz, ft4.xyz\n"+					// ft7.xyz =  perpendicular shifted position

				"nrm ft7.xyz, ft7.xyz\n"+							// ft7.xyz = normalized vector
				"mov ft4.w, fc0.x\n"+								// ft4.w = 0; as accumulator

				// ----- center vector
				"tex ft4.xyz, ft7.xyz, fs"+(4+idx)+" <cube,nearest>\n"+	// ft4=value depthTexture coordinate
				"dp3 ft4.x, ft4.rgb, fc"+(numLights*2+4)+".xyz\n"+	// ft4.w= dist value from depth texture
				"slt ft4.x, ft7.w, ft4.x\n"+						// ft4x=1 if ft7<ft4 else 0
				"add ft4.w, ft4.w, ft4.x\n"+

				// ----- left vector
				"sub ft7.x, ft7.x, fc"+(numLights*2+4)+".w\n"+		// x-=0.01
				"tex ft4.xyz, ft7.xyz, fs"+(4+idx)+" <cube,nearest>\n"+	// ft4=value depthTexture coordinate
				"dp3 ft4.x, ft4.rgb, fc"+(numLights*2+4)+".xyz\n"+	// ft4.w= dist value from depth texture
				"slt ft4.x, ft7.w, ft4.x\n"+						// ft4x=1 if ft7<ft4 else 0
				"add ft4.w, ft4.w, ft4.x\n"+

				// ----- right vector
				"add ft7.x, ft7.x, fc"+(numLights*2+4)+".w\n"+		// x+=0.01
				"add ft7.x, ft7.x, fc"+(numLights*2+4)+".w\n"+		// x+=0.01
				"tex ft4.xyz, ft7.xyz, fs"+(4+idx)+" <cube,nearest>\n"+	// ft4=value depthTexture coordinate
				"dp3 ft4.x, ft4.rgb, fc"+(numLights*2+4)+".xyz\n"+	// ft4.w= dist value from depth texture
				"slt ft4.x, ft7.w, ft4.x\n"+						// ft4x=1 if ft7<ft4 else 0
				"add ft4.w, ft4.w, ft4.x\n"+

				// ----- up vector
				"sub ft7.x, ft7.x, fc"+(numLights*2+4)+".w\n"+		// x-=0.01
				"sub ft7.y, ft7.y, fc"+(numLights*2+4)+".w\n"+		// y-=0.01
				"tex ft4.xyz, ft7.xyz, fs"+(4+idx)+" <cube,nearest>\n"+	// ft4=value depthTexture coordinate
				"dp3 ft4.x, ft4.rgb, fc"+(numLights*2+4)+".xyz\n"+	// ft4.w= dist value from depth texture
				"slt ft4.x, ft7.w, ft4.x\n"+						// ft4x=1 if ft7<ft4 else 0
				"add ft4.w, ft4.w, ft4.x\n"+

				// ----- down vector
				"add ft7.y, ft7.y, fc"+(numLights*2+4)+".w\n"+		// y+=0.01
				"add ft7.y, ft7.y, fc"+(numLights*2+4)+".w\n"+		// y+=0.01
				"tex ft4.xyz, ft7.xyz, fs"+(4+idx)+" <cube,nearest>\n"+	// ft4=value depthTexture coordinate
				"dp3 ft4.x, ft4.rgb, fc"+(numLights*2+4)+".xyz\n"+	// ft4.w= dist value from depth texture
				"slt ft4.x, ft7.w, ft4.x\n"+						// ft4x=1 if ft7<ft4 else 0
				"add ft4.w, ft4.w, ft4.x\n"+

				// ----- foward vector
				"sub ft7.y, ft7.y, fc"+(numLights*2+4)+".w\n"+		// y-=0.01
				"sub ft7.z, ft7.z, fc"+(numLights*2+4)+".w\n"+		// z-=0.01
				"tex ft4.xyz, ft7.xyz, fs"+(4+idx)+" <cube,nearest>\n"+	// ft4=value depthTexture coordinate
				"dp3 ft4.x, ft4.rgb, fc"+(numLights*2+4)+".xyz\n"+	// ft4.w= dist value from depth texture
				"slt ft4.x, ft7.w, ft4.x\n"+						// ft4x=1 if ft7<ft4 else 0
				"add ft4.w, ft4.w, ft4.x\n"+

				// ----- back vector
				"add ft7.z, ft7.z, fc"+(numLights*2+4)+".w\n"+		// z+=0.01
				"add ft7.z, ft7.z, fc"+(numLights*2+4)+".w\n"+		// z+=0.01
				"tex ft4.xyz, ft7.xyz, fs"+(4+idx)+" <cube,nearest>\n"+	// ft4=value depthTexture coordinate
				"dp3 ft4.x, ft4.rgb, fc"+(numLights*2+4)+".xyz\n"+	// ft4.w= dist value from depth texture
				"slt ft4.x, ft7.w, ft4.x\n"+						// ft4x=1 if ft7<ft4 else 0
				"add ft4.w, ft4.w, ft4.x\n"+

				"mov ft4.xyz, fc0.zzw\n"+							// ft4.xyz = 1,1,2
				"dp3 ft4.x, ft4.xyz, ft4.xyz\n"+					// ft4.x = 1+1+4
				"div ft4.xyzw, ft4.wwww, ft4.xxxx\n";				// output
			return s;
		}//endfunction

		/**
		* references shadow map texture when calculating illuminated pixel color
		* inputs:		v0= transformed vertex
		*				v1= transformed normal
		*				v2= UV
		*				v4=[nearClip,farClip,focalL,aspectRatio]
		* constants:	fc0= [0,0.5,1,2]	// useful constants
		*				fc1= [r,g,b,sf]		// ambient and specular factor
		*				fc2= [r,g,b,fogD]	// linear fog factor
		*				...
		*				fc_i*2+4= [px,py,pz,bias]	// light n point
		*				fc_i*2+5= [r,g,b,1-1/bias]	// light n color
		*				fc_n*2+4= [64*64,64,1,1/64]	// useful constants
		* output: 		ft4= 1 or 0
		*/
		private static function _cubeShadowFragSrc(idx:uint,numLights:uint) : String
		{
			var s:String =
				"sub ft7.xyz, v0.xyz,  fc"+(idx*2+4)+".xyz\n"+		// ft7= posn from light POV
				"dp3 ft7.w, ft7.xyz, ft7.xyz\n"+					// ft7.w = dist squared from light src
				"sqt ft7.w, ft7.w\n"+								// ft7.w = dist
/*
				// ----- perspective correction bias
				"mov ft4.xyz, fc"+(idx*2+4)+".xyz\n"+
				"neg ft4.xyz, ft4.xyz\n"+							// ft4.xyz = cam posn from light POV
				"dp3 ft4.w, ft4.xyz, ft4.xyz\n"+					//
				"sqt ft4.w, ft4.w\n"+								// ft4.w = dist to cam from light
				"div ft4.xyz, ft4.xyz, ft4.www\n"+					// ft4.xyz = unit vector to cam from light
				"dp3 ft4.w, ft4.xyz, ft7.xyz\n"+					// ft4.w = proj dist onto unit camV
				"mul ft4.xyz, ft4.xyz, ft4.www\n"+					// ft4.xyz =
				"sub ft4.xyz, ft7.xyz, ft4.xyz\n"+					// ft4.xyz = perpendicular vector to posn
				"div ft4.w, ft4.w, ft7.w\n"+						// ft4.w = cosAng
				"mul ft4.w, ft4.w, fc"+(idx*2+4)+".w\n"+			// ft4.w from -bias to bias
				"add ft4.w, ft4.w, fc"+(idx*2+4)+".w\n"+			// ft4.w from 0 to 2bias
				"sub ft4.w, ft4.w, fc"+(idx*2+5)+".w\n"+			//
				"mul ft4.xyz, ft4.xyz, ft4.www\n"+					// ft4.xyz = adjusted perpendicular vector from camV to vertex
				"add ft7.xyz, ft7.xyz, ft4.xyz\n"+					// ft7.xyz =  perpendicular shifted position
*/
				// ----- chk shadow z map, if in shadows, do not add ft3
				"tex ft4, ft7.xyz, fs"+(4+idx)+" <cube,nearest>\n"+	// ft4=value depthTexture coordinate
				"dp4 ft4.w, ft4, fc"+(numLights*2+4)+"\n"+			// ft4.w= dist value from depth texture
				"slt ft4, ft7.wwww, ft4.wwww\n";					// ft4=1 if ft7<ft4 else 0
			return s;
		}//endfunction

		/**
		* render to depth texture vertex shader render src (18 instructions)
		* inputs: 		vt0 = vertex vx,vy,vz
		* constants:	vc0=[nearClip,farClip,focalL,1], vc1-vc4=TransformMatrix
		* frag outputs:	v0= transformed vertex
		*/
		private static function _depthCubePersVertSrc() : String
		{
			var s:String =
			"m34 vt0.xyz, vt0, vc1\n" +			// vt0=apply view transform to vertex
			"dp3 vt0.w, vt0.xyz, vt0.xyz\n"+	// vt0.w = dist Squared from center
			"sqt vt0.w, vt0.w\n"+				// vt0.w = dist
			"mov v0, vt0\n" +					// output dist Sq to fragment shader v0
/*
			// ----- perspective correction bias
			"dp3 vt1.w, vt0.xyz, vc127.xyz\n"+	// vt1.w = proj dist onto unit camV
			"mul vt1.xyz, vc127.xyz, vt1.www\n"+// vt1.xyz = vector along unit camV
			"sub vt1.xyz, vt0.xyz, vt1.xyz\n"+	// vt1.xyz = perpendicular vector from camV to vertex
			"div vt1.w, vt1.w, vt0.w\n"+		// vt1.w = cosAng
			"mul vt1.w, vt1.w, vc127.w\n"+		// vt1.w from -bias to bias
			"add vt1.w, vt1.w, vc127.w\n"+		// vt1.w from 0 to 2bias
			"mov vt0.w, vc127.w\n"+
			"rcp vt0.w, vt0.w\n"+
			"sub vt0.w, vc0.w, vt0.w\n"+
			"max vt0.w, vt0.w, vc4.x\n"+
			"sub vt1.w, vt1.w, vt0.w\n" +		// vt1.w from -1+1/f to 2bias -1+1/f
			//"sub vt1.w, vt1.w, vc0.w\n"+	// TEST!
			"mul vt1.xyz, vt1.xyz, vt1.www\n"+	// vt1.xyz = adjusted perpendicular vector from camV to vertex
			"add vt0.xyz, vt0.xyz, vt1.xyz\n"+	// vt0.xyz = perpendicular shifted position
*/
			"div vt0.xyw, vt0.xyz, vc0.xxxx\n"+	// vt0.xyw = x/nearClip,y/nearClip,z/nearClip	(homogeneous coordinate)
			"mov vt0.z, vc4.w\n" + 				// vt0.z = 1
			// vt0.xyz will be automatically divided by vt0.w	depth buffer test (greater)
			"mov op, vt0\n";				// output transformed value

			return s;
		}//endfunction

		/**
		* inputs:		v0 = vx,vy,vz,dist
		* constants:	fc0 = [64*64,64,1,1/64]
		*				fc1 = [0,0,0,0]
		*/
		private static function _depthCubeFragSrc() : String
		{
			var s:String =
			"mul ft0.w, v0.w, fc0.y\n"+
			"div ft0.xyzw, ft0.wwww, fc0.xyzw\n"+
			"frc ft1, ft0\n"+
			"sub ft0, ft0, ft1\n"+
			"mul ft0, ft0, fc0.w\n"+
			"frc oc, ft0\n";
			return s;
		}//endfunction

		private static var bloomFilterData:BloomFilterData = null;
	}//endclass
}//endpackage

import core3D.*;
import flash.display3D.Context3D;
import flash.display3D.IndexBuffer3D;
import flash.display3D.Program3D;
import flash.display3D.textures.Texture;
import flash.display3D.VertexBuffer3D;
import flash.geom.Vector3D;


class BloomFilterData
{
	private var vertexBuffer:VertexBuffer3D = null;
	private var indexBuffer:IndexBuffer3D = null;
	private var treshProg:Program3D = null;
	private var hBlurProg:Program3D = null;
	private var vBlurProg:Program3D = null;
	private var tmpA:Texture = null;
	private var tmpB:Texture = null;

	private static var context3d:Context3D = null;
	private static var uploadedPrograms:Array = null;

	/**
	*
	*/
	public function BloomFilterData(context:Context3D) : void
	{
		context3d = context;

		// ----- set to vertexBuffer draw a large rectangle
		vertexBuffer=context3d.createVertexBuffer(4, 6);	// vx,vy,vz,vw,u,v
		vertexBuffer.uploadFromVector(Vector.<Number>([-1,1,1,1,0,0, 1,1,1,1,1,0, 1,-1,1,1,1,1, -1,-1,1,1,0,1]), 0, 4);
		indexBuffer=context3d.createIndexBuffer(6);
		indexBuffer.uploadFromVector(Vector.<uint>([0,1,2,0,2,3]),0,6);

		// ----- create
		var vertSrc:String =
		"mov op, va0\n" +
		"mov v0, va1.xyxy\n";	// output uv to v0

		treshProg = createProgram(vertSrc,getTresholdFrgSrc());
		hBlurProg = createProgram(vertSrc,getBlurFragSrc(16,true));
		vBlurProg = createProgram(vertSrc,getBlurFragSrc(16,false,true));
	}//endConstr

	/**
	* pass in the scene rendered to tex, with width and height of tex
	*/
	public function render(tex:Texture,blurX:int,blurY:int,cutOff:Number=0.9,intensity:Number=2):void
	{
		// ----- initialise and clear bindings
		var bloomTexSize:int = 256;
		if (tmpA==null)	tmpA = context3d.createTexture(bloomTexSize,bloomTexSize,"bgra", true);
		if (tmpB==null)	tmpB = context3d.createTexture(bloomTexSize,bloomTexSize,"bgra", true);
		var i:int=0;
		var stepSize:Number = 1/bloomTexSize;
		var P:Vector.<Number> = null;
		for (i=0; i<8; i++)	context3d.setVertexBufferAt(i, null);
		for (i=0; i<8; i++)	context3d.setTextureAt(i,null);

		// ----- render threshold texture
		//context3d.setRenderToBackBuffer();
		context3d.setRenderToTexture(tmpA,false,4);	// output to tmpA
		context3d.clear(0,0,0,0,0,0,0xFFFFFFFF);	// clear depth buffer to 0s
		context3d.setTextureAt(0,tex);				// input as tex
		context3d.setCulling("none");
		context3d.setVertexBufferAt(0, vertexBuffer, 0, "float4");	// va0 to expect vertices
		context3d.setVertexBufferAt(1, vertexBuffer, 4, "float2");	// va1 to expect UV
		context3d.setProgramConstantsFromVector("fragment", 0, Vector.<Number>([1, stepSize, cutOff, 1-cutOff]));
		context3d.setProgram(treshProg);			// use threshold program to draw
		context3d.drawTriangles(indexBuffer);

		// ----- render x blur
		//context3d.setRenderToBackBuffer();
		context3d.setRenderToTexture(tmpB,false,4);	// output to tmpB
		context3d.clear(0,0,0,0,0,0,0xFFFFFFFF);	// clear depth buffer to 0s
		context3d.setTextureAt(0,tmpA);				// input as tmpA
		P = new Vector.<Number>();
		for (i=0; i<=16; i++)
			P.push(intensity*Math.exp(-i*i/(2*blurX))/(Math.sqrt(blurX)*Math.sqrt(2*Math.PI)));
		while (P.length%4!=0)	P.push(0);
		context3d.setProgramConstantsFromVector("fragment",1,P);
		context3d.setProgram(hBlurProg);
		context3d.drawTriangles(indexBuffer);

		// ----- render y blur on x blur
		context3d.setRenderToBackBuffer();
		context3d.clear(0,0,0,0,0,0,0xFFFFFFFF);	// clear depth buffer to 0s
		context3d.setTextureAt(0,tmpB);				// bind glow texture to 0
		context3d.setTextureAt(1,tex);				// bind original texture to 1
		stepSize = 1/bloomTexSize;
		context3d.setProgramConstantsFromVector("fragment", 0, Vector.<Number>([1, stepSize, cutOff, 1-cutOff]));
		P = new Vector.<Number>();
		for (i=0; i<=16; i++)
			P.push(intensity*Math.exp(-i*i/(2*blurY))/(Math.sqrt(blurY)*Math.sqrt(2*Math.PI)));
		while (P.length%4!=0)	P.push(0);
		context3d.setProgramConstantsFromVector("fragment",1,P);
		context3d.setProgram(vBlurProg);
		context3d.drawTriangles(indexBuffer);

		context3d.present();

		for (i=0; i<8; i++)	context3d.setVertexBufferAt(i, null);
		for (i=0; i<8; i++)	context3d.setTextureAt(i,null);

	}//endfunction

	/**
	*
	*/
	private static function getTresholdFrgSrc() : String
	{
		var s:String =
			"tex ft0, v0, fs0 <2d,linear,mipnone,clamp>\n"+ // ft0 = tex color val
			"sub ft0.xyz, ft0.xyz, fc0.zzz\n"+				// ft0.xyz-=cutoff
			"div ft0.xyz, ft0.xyz, fc0.www\n"+				// ft0.xyz = (rgb-cutoff)/(1-cutoff)
			"sat oc, ft0\n";
		return s;
	}//endfunction

	/**
	* 11*blr+9 instrs
	*/
	private static function getBlurFragSrc(blr:uint,dirX:Boolean=true,merge:Boolean=false):String
	{
		var s:String =
		"tex ft2, v0, fs0 <2d,linear,mipnone,clamp>\n"+	// ft2 = tex color val
		"mul ft2.xyz, ft2.xyz, fc1.xxx\n"+				// ft2.xyz = tex color * p
		"mov ft1.xyzw, fc0.yyyy\n";						// ft1.xyzw = stepSize
		var a:String = "xyzw";
		for (var i:int=1; i<=blr; i++)	// 11*n instrs
		{
			var ii:int = i%4;
			var sel:String = a.charAt(ii)+a.charAt(ii)+a.charAt(ii)+"";

			s +="mov ft0, v0\n";						// ft0 = UV;
			if (dirX)	s+="add ft0.x, ft0.x, ft1.x\n";	// ft0 = UV with x offset
			else		s+="add ft0.y, ft0.y, ft1.y\n";	// ft0 = UV with y offset
			s +=
			"tex ft7, ft0, fs0 <2d,linear,mipnone,clamp>\n"+ // texture color val
			"mul ft7, ft7, fc"+int(i/4+1)+"."+sel+"\n"+	// ft7 = color * p
			"add ft2.xyz, ft2.xyz, ft7.xyz\n"+			// ft2+= accumulated color vals
			"mov ft0, v0\n";							// ft0 = UV;
			if (dirX)	s+="sub ft0.x, ft0.x, ft1.x\n";	// ft0 = UV with x offset
			else		s+="sub ft0.y, ft0.y, ft1.y\n";	// ft0 = UV with y offset
			s +=
			"tex ft7, ft0, fs0 <2d,linear,mipnone,clamp>\n"+ // texture color val
			"mul ft7, ft7, fc"+int(i/4+1)+"."+sel+"\n"+	// ft7 = color * p
			"add ft2.xyz, ft2.xyz, ft7.xyz\n"+			// ft2+= accumulated color vals
			"add ft1.xyzw, ft1.xyzw, fc0.yyyy\n";		// increment dist by step size
		}

		if (merge)
		s+= "tex ft1, v0, fs1 <2d,linear,mipnone,clamp>\n"+	// original texture color
			"add ft2.xyz, ft2.xyz, ft1.xyz\n";			// add original texture color

		s+="mov oc, ft2\n";								// output combined glow color

		return s;
	}//endfunction

	/**
	* given vertex and fragment sources create upload and returns a shader program
	*/
	private static function createProgram(agalVertexSource:String,agalFragmentSource:String) : Program3D
	{
		// ----- chk for already cached program for reuse
		var idstr:String = agalVertexSource+"\n\n"+agalFragmentSource;
		if (uploadedPrograms==null)	uploadedPrograms=[];
		var idx:int=uploadedPrograms.indexOf(idstr);
		if (idx!=-1) return uploadedPrograms[idx+1];	// returns previously compiled program

		// ----- build new program if no cached program is found
		var prog:Program3D = null;
		var agalVertex:AGALMiniAssembler=new AGALMiniAssembler();
		var agalFragment:AGALMiniAssembler=new AGALMiniAssembler();
		agalVertex.assemble("vertex", agalVertexSource);
		agalFragment.assemble("fragment", agalFragmentSource);
		prog = context3d.createProgram();
		prog.upload(agalVertex.agalcode, agalFragment.agalcode);

		// ----- cache program for future reuse, upload is expensive
		uploadedPrograms.push(idstr,prog);

		return prog;
	}//endfunction
}//endclass

/**
* private class to hold collision geometry data, for static shapes only
*/
class CollisionGeometry
{
	public var minXYZ:Vector3D;
	public var maxXYZ:Vector3D;
	public var radius:Number;
	public var Tris:Vector.<TriData>;

	private var BoundingTris:Vector.<TriData> = null;	// triangles that makes up the bounding cube of this geometry

	/**
	* creates Tris data and calculates max min and bounding radius
	* vertData : [vx,vy,vz,nx,n,nz,tx,ty,tz,u,v,...]
	* idxsData : [idxt1a,idxt1b,idxt1c,...]
	*/
	public function CollisionGeometry(vertData:Vector.<Number>,idxsData:Vector.<uint>=null) : void
	{
		radius = 0;
		minXYZ = new Vector3D( Number.MAX_VALUE, Number.MAX_VALUE, Number.MAX_VALUE);
		maxXYZ = new Vector3D(-Number.MAX_VALUE,-Number.MAX_VALUE,-Number.MAX_VALUE);
		Tris = new Vector.<TriData>();

		// ----- generate indices data for triangles ------------------
		if (idxsData==null)
		{
			idxsData=new Vector.<uint>();
			var nv:uint = vertData.length/11;
			for (i=0; i<nv; i++)	idxsData.push(i);
		}

		var n:int = idxsData.length;
		for (var i:int=0; i<n; i+=3)
		{
			// ----- get vertices -------------------------------
			var idx1:int = idxsData[i+0]*11;
			var idx2:int = idxsData[i+1]*11;
			var idx3:int = idxsData[i+2]*11;
			var td:TriData =
			new TriData(vertData[idx1+0],vertData[idx1+1],vertData[idx1+2],
						vertData[idx2+0],vertData[idx2+1],vertData[idx2+2],
						vertData[idx3+0],vertData[idx3+1],vertData[idx3+2]);
			Tris.push(td);

			radius = Math.max(	radius,
								td.ax*td.ax+td.ay*td.ay+td.az*td.az,
								td.bx*td.bx+td.by*td.by+td.bz*td.bz,
								td.cx*td.cx+td.cy*td.cy+td.cz*td.cz);

			minXYZ.x=Math.min(minXYZ.x,td.ax,td.bx,td.cx);
			minXYZ.y=Math.min(minXYZ.y,td.ay,td.by,td.cy);
			minXYZ.z=Math.min(minXYZ.z,td.az,td.bz,td.cz);
			maxXYZ.x=Math.max(maxXYZ.x,td.ax,td.bx,td.cx);
			maxXYZ.y=Math.max(maxXYZ.y,td.ay,td.by,td.cy);
			maxXYZ.z=Math.max(maxXYZ.z,td.az,td.bz,td.cz);
		}

		BoundingTris =
		Vector.<TriData>([new TriData(	minXYZ.x,minXYZ.y,minXYZ.z,		// front plane
										maxXYZ.x,minXYZ.y,minXYZ.z,
										maxXYZ.x,maxXYZ.y,minXYZ.z),
						new TriData(	minXYZ.x,minXYZ.y,minXYZ.z,
										minXYZ.x,maxXYZ.y,minXYZ.z,
										maxXYZ.x,maxXYZ.y,minXYZ.z),

						new TriData(	minXYZ.x,minXYZ.y,maxXYZ.z,		// back plane
										maxXYZ.x,minXYZ.y,maxXYZ.z,
										maxXYZ.x,maxXYZ.y,maxXYZ.z),
						new TriData(	minXYZ.x,minXYZ.y,maxXYZ.z,
										minXYZ.x,maxXYZ.y,maxXYZ.z,
										maxXYZ.x,maxXYZ.y,maxXYZ.z),

						new TriData(	minXYZ.x,minXYZ.y,minXYZ.z,		// left plane
										minXYZ.x,maxXYZ.y,minXYZ.z,
										minXYZ.x,maxXYZ.y,maxXYZ.z),
						new TriData(	minXYZ.x,minXYZ.y,minXYZ.z,
										minXYZ.x,minXYZ.y,maxXYZ.z,
										minXYZ.x,maxXYZ.y,maxXYZ.z),

						new TriData(	maxXYZ.x,minXYZ.y,minXYZ.z,		// right plane
										maxXYZ.x,maxXYZ.y,minXYZ.z,
										maxXYZ.x,maxXYZ.y,maxXYZ.z),
						new TriData(	maxXYZ.x,minXYZ.y,minXYZ.z,
										maxXYZ.x,minXYZ.y,maxXYZ.z,
										maxXYZ.x,maxXYZ.y,maxXYZ.z),

						new TriData(	minXYZ.x,minXYZ.y,minXYZ.z,		// bottom plane
										maxXYZ.x,minXYZ.y,minXYZ.z,
										maxXYZ.x,minXYZ.y,maxXYZ.z),
						new TriData(	minXYZ.x,minXYZ.y,minXYZ.z,
										minXYZ.x,minXYZ.y,maxXYZ.z,
										maxXYZ.x,minXYZ.y,maxXYZ.z),

						new TriData(	minXYZ.x,maxXYZ.y,minXYZ.z,		// top plane
										maxXYZ.x,maxXYZ.y,minXYZ.z,
										maxXYZ.x,maxXYZ.y,maxXYZ.z),
						new TriData(	minXYZ.x,maxXYZ.y,minXYZ.z,
										minXYZ.x,maxXYZ.y,maxXYZ.z,
										maxXYZ.x,maxXYZ.y,maxXYZ.z)]);

		radius = Math.sqrt(radius);
	}//endConstructor

	/**
	*
	*/
	public static function cube(l:Number,w:Number,h:Number) : CollisionGeometry
	{
		l/=2;
		w/=2;
		h/=2;
		var V:Vector.<Number> =
		Vector.<Number>([	-l,-w,-h,	0,0,0,0,0,	// bottom
							l,-w,-h,	0,0,0,0,0,
							l,w,-h,		0,0,0,0,0,
							-l,-w,-h,	0,0,0,0,0,
							l,w,-h,		0,0,0,0,0,
							-l,w,-h,	0,0,0,0,0,

							-l,-w,h,	0,0,0,0,0,	// top
							l,-w,h,		0,0,0,0,0,
							l,w,h,		0,0,0,0,0,
							-l,-w,h,	0,0,0,0,0,
							l,w,h,		0,0,0,0,0,
							-l,w,h,		0,0,0,0,0,

							-l,-w,h,	0,0,0,0,0,	// back
							-l,w,h,		0,0,0,0,0,
							-l,w,-h,	0,0,0,0,0,
							-l,-w,h,	0,0,0,0,0,
							-l,w,-h,	0,0,0,0,0,
							-l,-w,-h,	0,0,0,0,0,

							l,-w,h,		0,0,0,0,0,	// front
							l,w,h,		0,0,0,0,0,
							l,w,-h,		0,0,0,0,0,
							l,-w,h,		0,0,0,0,0,
							l,w,-h,		0,0,0,0,0,
							l,-w,-h,	0,0,0,0,0,

							-l,-w,-h,	0,0,0,0,0,	// left
							-l,-w,h,	0,0,0,0,0,
							l,-w,-h,	0,0,0,0,0,
							-l,-w,-h,	0,0,0,0,0,
							 l,-w,-h,	0,0,0,0,0,
							-l,-w,-h,	0,0,0,0,0,

							-l,w,-h,	0,0,0,0,0,	// right
							-l,w,h,		0,0,0,0,0,
							l,w,-h,		0,0,0,0,0,
							-l,w,-h,	0,0,0,0,0,
							 l,w,-h,	0,0,0,0,0,
							-l,w,-h,	0,0,0,0,0
		]);

		return new CollisionGeometry(V);
	}//endfunction

	/**
	* scales the detection geometry
	*/
	public function scale(sx:Number,sy:Number,sz:Number) : void
	{
		radius = 0;
		for (var i:int=Tris.length-1; i>=0; i--)
		{
			var td:TriData = Tris[i];
			td.ax*=sx;
			td.ay*=sy;
			td.az*=sz;
			td.bx*=sx;
			td.by*=sy;
			td.bz*=sz;
			td.cx*=sx;
			td.cy*=sy;
			td.cz*=sz;
			radius = Math.max(	radius,
								td.ax*td.ax+td.ay*td.ay+td.az*td.az,
								td.bx*td.bx+td.by*td.by+td.bz*td.bz,
								td.cx*td.cx+td.cy*td.cy+td.cz*td.cz);
		}

		// because sign might be changed, must re-evaluate max min
		var ax:Number = minXYZ.x*sx;
		var bx:Number = maxXYZ.x*sx;
		var ay:Number = minXYZ.y*sy;
		var by:Number = maxXYZ.y*sy;
		var az:Number = minXYZ.z*sz;
		var bz:Number = maxXYZ.z*sz;
		minXYZ.x=Math.min(ax,bx);
		minXYZ.y=Math.min(ay,by);
		minXYZ.z=Math.min(az,bz);
		maxXYZ.x=Math.max(ax,bx);
		maxXYZ.y=Math.max(ay,by);
		maxXYZ.z=Math.max(az,bz);
		radius = Math.sqrt(radius);

		//trace("Tris:"+Tris.length+" min:"+minXYZ+" max:"+maxXYZ);
	}//endfunction

	/**
	* scales the detection geometry
	*/
	public function translate(tx:Number,ty:Number,tz:Number) : void
	{
		radius = 0;
		for (var i:int=Tris.length-1; i>=0; i--)
		{
			var td:TriData = Tris[i];
			td.ax+=tx;
			td.ay+=ty;
			td.az+=tz;
			td.bx+=tx;
			td.by+=ty;
			td.bz+=tz;
			td.cx+=tx;
			td.cy+=ty;
			td.cz+=tz;
			radius = Math.max(	radius,
								td.ax*td.ax+td.ay*td.ay+td.az*td.az,
								td.bx*td.bx+td.by*td.by+td.bz*td.bz,
								td.cx*td.cx+td.cy*td.cy+td.cz*td.cz);
		}

		// because sign might be changed, must re-evaluate max min
		minXYZ.x+=tx;
		minXYZ.y+=ty;
		minXYZ.z+=tz;
		maxXYZ.x+=tx;
		maxXYZ.y+=ty;
		maxXYZ.z+=tz;
		radius = Math.sqrt(radius);

		//trace("Tris:"+Tris.length+" min:"+minXYZ+" max:"+maxXYZ);
	}//endfunction

	/**
	* combines given list of collision geometry into 1
	*/
	public static function merge(CGs:Vector.<CollisionGeometry>) : CollisionGeometry
	{
		var Tris:Vector.<TriData> = new Vector.<TriData>();
		var radius:Number = 0;
		var minXYZ:Vector3D = new Vector3D( Number.MAX_VALUE, Number.MAX_VALUE, Number.MAX_VALUE);
		var maxXYZ:Vector3D = new Vector3D(-Number.MAX_VALUE,-Number.MAX_VALUE,-Number.MAX_VALUE);

		for (var i:int=CGs.length-1; i>=0; i--)
		{
			var cg:CollisionGeometry = CGs[i];
			for (var j:int=cg.Tris.length-1; j>=0; j--)
			{
				var td:TriData = cg.Tris[j];
				radius = Math.max(	radius,
								td.ax*td.ax+td.ay*td.ay+td.az*td.az,
								td.bx*td.bx+td.by*td.by+td.bz*td.bz,
								td.cx*td.cx+td.cy*td.cy+td.cz*td.cz);
				Tris.push(td);
				minXYZ.x=Math.min(minXYZ.x,td.ax,td.bx,td.cx);
				minXYZ.y=Math.min(minXYZ.y,td.ay,td.by,td.cy);
				minXYZ.z=Math.min(minXYZ.z,td.az,td.bz,td.cz);
				maxXYZ.x=Math.max(maxXYZ.x,td.ax,td.bx,td.cx);
				maxXYZ.y=Math.max(maxXYZ.y,td.ay,td.by,td.cy);
				maxXYZ.z=Math.max(maxXYZ.z,td.az,td.bz,td.cz);
			}

		}

		var ncg:CollisionGeometry = new CollisionGeometry(new Vector.<Number>());
		ncg.Tris = Tris;
		ncg.radius = radius;
		ncg.minXYZ = minXYZ;
		ncg.maxXYZ = maxXYZ;
		return ncg;
	}//endfunction

	/**
	* parses a given obj format string data s to a collection of CollisionGeometry
	*/
	public static function parseObj(s:String) : Vector.<CollisionGeometry>
	{
		//trace("CollisionGeometry.parseObj");
		var i:int = 0;
		var j:int = 0;
		//trace(s);

		// ----- read data from string
		var D:Array = s.split("\n");	// data array
		var V:Vector.<Number> = new Vector.<Number>();		// array to contain vertices data
		var F:Array = [];			// array to contain triangle faces data
		var G:Array = [];			// groups array, containing submeshes faces
		var A:Array = [];			// temp array

		var n:uint = D.length;
		for (i=0; i<n; i++)
		{
			if (D[i].substr(0,2)=="v ")				// ----- if position definition
			{
				A = (D[i].substr(2)).split(" ");
				for (j=A.length-1; j>=0; j--)
					if (A[j]=="")	A.splice(j,1);
				for (j=0; j<A.length && j<3; j++)
					V.push(Number(A[j]));
			}
			else if (D[i].substr(0,2)=="f ")		// ----- if face definition
			{
				A = (D[i].substr(2)).split(" ");	// ["v/uv/n","v/uv/n","v/uv/n"]
				for (j=A.length-1; j>=0; j--)
					if (A[j]=="")
						A.splice(j,1);
					else
					{
						while (A[j].split("/").length<3)	A[j] = A[j]+"/-";
						A[j] = A[j].split("//").join("/-/");	// replace null values with "-"
						A[j] = A[j].split("/"); 	// format of f : [[v,uv,n],[v,uv,n],[v,uv,n]]
						if (A[j][2]=="-")	A[j][2]=A[j][0];	// default normal to vertex idx
					}
				F.push(A);
			}
			else if (D[i].substr(0,2)=="o ")		// ----- if object definition
			{
				G.push(F);
				F = [];
			}
			else if (D[i].substr(0,2)=="g ")		// ----- if group definition
			{
				G.push(F);
				F = [];
			}
		}//endfor

		G.push(F);	// push last F

		// ----- start parsing geometry data to triangles -----------
		var CGs:Vector.<CollisionGeometry> = new Vector.<CollisionGeometry>();

		for (var g:int=0; g<G.length; g++)
		{
			F = G[g];

			// ----- import faces data -----------------------------
			var verticesData:Vector.<Number> = new Vector.<Number>(); // to contain [vx,vy,vz,nx,ny,nz,u,v, ....]
			for (i=0; i<F.length; i++)
			{
				var f:Array = F[i];		// data of a face: [[v,uv,n],[v,uv,n],[v,uv,n],...]

				for (j=0; j<f.length; j++)
				{
					var p:Array = f[j];	// data of a point:	[v,uv,n]
					for (var k:int=0; k<p.length; k++)
						p[k] = int(Number(p[k]))-1;
				}

				// ----- triangulate higher order polygons
				while (f.length>=3)
				{
					A = [];
					for (j=0; j<3; j++)
						A=A.concat(f[j]);
					// A: [v,uv,n,v,uv,n,v,uv,n]

					// ----- get vertices --------------------------------
					var vax:Number = V[A[0]*3+0];
					var vay:Number = V[A[0]*3+1];
					var vaz:Number = V[A[0]*3+2];
					var vbx:Number = V[A[3]*3+0];
					var vby:Number = V[A[3]*3+1];
					var vbz:Number = V[A[3]*3+2];
					var vcx:Number = V[A[6]*3+0];
					var vcy:Number = V[A[6]*3+1];
					var vcz:Number = V[A[6]*3+2];

					verticesData.push(	vax,vay,vaz, 0,0,0, 0,0,	// vertex normal uv
										vbx,vby,vbz, 0,0,0, 0,0,
										vcx,vcy,vcz, 0,0,0, 0,0);

					f.splice(1,1);
				}//endwhile
			}//endfor i

			if (verticesData.length>0)	CGs.push(new CollisionGeometry(verticesData));
		}//endfor g

		return CGs;
	}//endfunction

	/**
	* returns if line pt:(ox,oy,oz) vect:(vx,vy,vz) hits or is in the Bounding Box of this geometry
	*/
	public function lineHitsBounds(ox:Number,oy:Number,oz:Number,vx:Number,vy:Number,vz:Number) : Boolean
	{
		if (ox<minXYZ.x && ox+vx<minXYZ.x)	return false;
		if (ox>maxXYZ.x && ox+vx>maxXYZ.x)	return false;

		if (oy<minXYZ.y && oy+vy<minXYZ.y)	return false;
		if (oy>maxXYZ.y && oy+vy>maxXYZ.y)	return false;

		if (oz<minXYZ.z && oz+vz<minXYZ.z)	return false;
		if (oz>maxXYZ.z && oz+vz>maxXYZ.z)	return false;

		if (ox>=minXYZ.x && ox<=maxXYZ.x &&		//point is in object bounds
			oy>=minXYZ.y && oy<=maxXYZ.y &&
			oz>=minXYZ.z && oz<=maxXYZ.z)		return true;

		return _lineHitsGeometry(ox,oy,oz,vx,vy,vz,BoundingTris)!=null;
	}//endfunction

	/**
	* returns point where line pt:(lox,loy,loz) vect:(lvx,lvy,lvz) hits this geometry
	* returns {vx,vy,vz, nx,ny,nz}	where (vx,vy,vz) is hit point and (nx,ny,nz) is triangle normal
	*/
	public function lineHitsGeometry(lox:Number,loy:Number,loz:Number,lvx:Number,lvy:Number,lvz:Number) : VertexData
	{
		return _lineHitsGeometry(lox,loy,loz,lvx,lvy,lvz,Tris);
	}//endfunction

	/**
	* returns point where line pt:(lox,loy,loz) vect:(lvx,lvy,lvz) hits this geometry
	* returns {vx,vy,vz, nx,ny,nz}	where (vx,vy,vz) is hit point and (nx,ny,nz) is triangle normal
	*/
	private function _lineHitsGeometry(lox:Number,loy:Number,loz:Number,lvx:Number,lvy:Number,lvz:Number,Tris:Vector.<TriData>) : VertexData
	{
		var hit:VertexData = null;
		for (var i:int=Tris.length-1; i>=0; i--)
		{
			var tri:TriData = Tris[i];

			// ----- chk line hits this triangle --------------------
			var ipt:VertexData = null;//tri.lineIntersection(lox,loy,loz,lvx,lvy,lvz,true);

			// ***** Optimization ***********************************
			var ax:Number = tri.ax;
			var ay:Number = tri.ay;
			var az:Number = tri.az;
			var bx:Number = tri.bx;
			var by:Number = tri.by;
			var bz:Number = tri.bz;
			var cx:Number = tri.cx;
			var cy:Number = tri.cy;
			var cz:Number = tri.cz;

			var nx:Number = tri.nx;	//	normal x for the triangle
			var ny:Number = tri.ny;	//	normal y for the triangle
			var nz:Number = tri.nz;	//	normal z for the triangle

			// let X be the intersection point, then equation of triangle plane Tn.(X-Ta) = 0
			// but X = Lo+Lv*k   =>   Tn.(Lo+Lv*k-Ta) = 0    =>   Tn.Lv*k + Tn.(Lo-Ta) = 0
			// k = (Ta-Lo).Tn/Lv.Tn
			// denom!=0 => there is intersection in the plane of tri

			var denom:Number = lvx*nx+lvy*ny+lvz*nz;
			if (denom!=0)		// has intersection
			{
				var num:Number = (nx*(ax-lox) + ny*(ay-loy) + nz*(az-loz));
				var k:Number = num/denom;
				if (k>=0 && k<=1)	// has segment intersection
				{
					var ix:Number = lox+lvx*k - ax;		// vector to segment intersection on triangle plane
					var iy:Number = loy+lvy*k - ay;		// vector to segment intersection on triangle plane
					var iz:Number = loz+lvz*k - az;		// vector to segment intersection on triangle plane

					var px:Number = bx - ax;		// tri side vector from a to b
					var py:Number = by - ay;		// tri side vector from a to b
					var pz:Number = bz - az;		// tri side vector from a to b

					var qx:Number = cx - ax;		// tri side vector from a to c
					var qy:Number = cy - ay;		// tri side vector from a to c
					var qz:Number = cz - az;		// tri side vector from a to c

					// find scalars along triangle sides P and Q s.t. sP+tQ = I
					// s = (p.q)(w.q)-(q.q)(w.p)/(p.q)(p.q)-(p.p)(q.q)
					// t = (p.q)(w.p)-(p.p)(w.q)/(p.q)(p.q)-(p.p)(q.q)
					var p_p:Number = px*px+py*py+pz*pz;
					var q_q:Number = qx*qx+qy*qy+qz*qz;
					var p_q:Number = px*qx+py*qy+pz*qz;
					var w_p:Number = ix*px+iy*py+iz*pz;
					var w_q:Number = ix*qx+iy*qy+iz*qz;

					denom = p_q*p_q - p_p*q_q;
					var s:Number = (p_q*w_q - q_q*w_p)/denom;
					var t:Number = (p_q*w_p - p_p*w_q)/denom;

					if (!(s<0 || t<0 || s+t>1)) // intersection inside triangle
					{
						var _nl:Number = 1/Math.sqrt(nx*nx+ny*ny+nz*nz);
						nx*=_nl;	ny*=_nl;	nz*=_nl;
						ipt = new VertexData(ax+s*px+t*qx,	// return intersection point within tri
											ay+s*py+t*qy,	// return intersection point within tri
											az+s*pz+t*qz,	// return intersection point within tri
											nx,ny,nz);		// triangle normal
					}
				}
			}
			// ***** Optimization ***********************************

			if (hit==null)
				hit=ipt;
			else if (ipt!=null)
			{
				var idx:Number = ipt.vx-lox;
				var idy:Number = ipt.vy-loy;
				var idz:Number = ipt.vz-loz;
				var ndx:Number = hit.vx-lox;
				var ndy:Number = hit.vy-loy;
				var ndz:Number = hit.vz-loz;
				if (idx*idx+idy*idy+idz*idz<ndx*ndx+ndy*ndy+ndz*ndz)
					hit=ipt;
			}
		}//endfor

		return hit;
	}//endFunction

	/**
	* returns if line pt:(ox,oy,oz) vect:(vx,vy,vz) hits or is in the Bounding Box of this geometry
	*/
	public function sphereHitsBounds(ox:Number,oy:Number,oz:Number,r:Number) : Boolean
	{
		if (ox<minXYZ.x && ox+r<minXYZ.x)	return false;
		if (ox>maxXYZ.x && ox+r>maxXYZ.x)	return false;

		if (oy<minXYZ.y && oy+r<minXYZ.y)	return false;
		if (oy>maxXYZ.y && oy+r>maxXYZ.y)	return false;

		if (oz<minXYZ.z && oz+r<minXYZ.z)	return false;
		if (oz>maxXYZ.z && oz+r>maxXYZ.z)	return false;

		if (ox>=minXYZ.x && ox<=maxXYZ.x &&		//point is in object bounds
			oy>=minXYZ.y && oy<=maxXYZ.y &&
			oz>=minXYZ.z && oz<=maxXYZ.z)		return true;

		return _sphereHitsGeometry(ox,oy,oz,r,BoundingTris)!=null;
	}//endfunction

	/**
	* returns point where sphere pt:(ox,oy,oz) radius:r hits this geometry
	* returns {vx,vy,vz, nx,ny,nz}	where (vx,vy,vz) is hit point and (nx,ny,nz) is triangle normal
	*/
	public function sphereHitsGeometry(ox:Number,oy:Number,oz:Number,r:Number) : Vector3D
	{
		return _sphereHitsGeometry(ox,oy,oz,r,Tris);
	}//endfunction

	/**
	* returns point where sphere pt:(ox,oy,oz) radius:r hits this geometry
	* returns {vx,vy,vz, nx,ny,nz}	where (vx,vy,vz) is hit point and (nx,ny,nz) is triangle normal
	*/
	private function _sphereHitsGeometry(ox:Number,oy:Number,oz:Number,r:Number,Tris:Vector.<TriData>=null) : Vector3D
	{
		var hit:Vector3D = null;
		for (var i:int=Tris.length-1; i>=0; i--)
		{
			var tri:TriData = Tris[i];

			// ----- chk sphere hits this triangle --------------------
			var ax:Number = tri.ax;
			var ay:Number = tri.ay;
			var az:Number = tri.az;
			var bx:Number = tri.bx;
			var by:Number = tri.by;
			var bz:Number = tri.bz;
			var cx:Number = tri.cx;
			var cy:Number = tri.cy;
			var cz:Number = tri.cz;
			var nx:Number = tri.nx;	//	normal x for the triangle
			var ny:Number = tri.ny;	//	normal y for the triangle
			var nz:Number = tri.nz;	//	normal z for the triangle

			// let X be the intersection point, then equation of triangle plane Tn.(X-Ta) = 0
			// but X = o+Tn*k   =>   Tn.(o+Tn*k-Ta) = 0    =>   Tn.Tn*k + Tn.(o-Ta) = 0
			// k = (Ta-o).Tn/Tn.Tn
			// but Tn.Tn == 1   =>  k = (Ta-o).Tn

			var k:Number = nx*(ax-ox) + ny*(ay-oy) + nz*(az-oz);
			if (k>=-r && k<=0)	// if sphere intersects plane
			{
				var ix:Number = ox+nx*k - ax;		// vector to segment intersection on triangle plane
				var iy:Number = oy+ny*k - ay;		// vector to segment intersection on triangle plane
				var iz:Number = oz+nz*k - az;		// vector to segment intersection on triangle plane

				var px:Number = bx - ax;		// tri side vector from a to b
				var py:Number = by - ay;		// tri side vector from a to b
				var pz:Number = bz - az;		// tri side vector from a to b

				var qx:Number = cx - ax;		// tri side vector from a to c
				var qy:Number = cy - ay;		// tri side vector from a to c
				var qz:Number = cz - az;		// tri side vector from a to c

				// find scalars along triangle sides P and Q s.t. sP+tQ = I
				// s = (p.q)(w.q)-(q.q)(w.p)/(p.q)(p.q)-(p.p)(q.q)
				// t = (p.q)(w.p)-(p.p)(w.q)/(p.q)(p.q)-(p.p)(q.q)
				var p_p:Number = px*px+py*py+pz*pz;
				var q_q:Number = qx*qx+qy*qy+qz*qz;
				var p_q:Number = px*qx+py*qy+pz*qz;
				var w_p:Number = ix*px+iy*py+iz*pz;
				var w_q:Number = ix*qx+iy*qy+iz*qz;

				var denom:Number = p_q * p_q - p_p * q_q;
				if (denom != 0)
				{
					var s:Number = (p_q*w_q - q_q*w_p)/denom;
					var t:Number = (p_q*w_p - p_p*w_q)/denom;

					//Mesh.debugTrace("sphereHitsGeometry s "+s+"  t="+t+"  denom="+denom+" k="+k+" r="+r);

					if (s < 0 || t<0 || s+t>1)		// if nearest point not within triangle
					{
						ax -= ox;
						ay -= oy;
						az -= oz;
						if (ax*ax+ay*ay+az*az<=r*r)	{r=Math.sqrt(ax*ax+ay*ay+az*az); hit=new Vector3D(ax+ox,ay+oy,az+oz);}
						bx -= ox;
						by -= oy;
						bz -= oz;
						if (bx*bx+by*by+bz*bz<=r*r)	{r=Math.sqrt(bx*bx+by*by+bz*bz); hit=new Vector3D(bx+ox,by+oy,bz+oz);}
						cx -= ox;
						cy -= oy;
						cz -= oz;
						if (cx*cx+cy*cy+cz*cz<=r*r)	{r=Math.sqrt(cx*cx+cy*cy+cz*cz); hit=new Vector3D(cx+ox,cy+oy,cz+oz);}
					}
					else
					{
						hit = new Vector3D(	ax+s*px+t*qx,	// return intersection point within tri
											ay+s*py+t*qy,	// return intersection point within tri
											az+s*pz+t*qz);	// return intersection point within tri
						r = Math.sqrt((hit.x-ox)*(hit.x-ox) + (hit.y-oy)*(hit.y-oy) + (hit.z-oz)*(hit.z-oz));
					}
				}
				else
				{
					Mesh.debugTrace("sphereHitsGeometry denom="+denom+" k="+k+" r="+r+"\ntri:"+tri.toString());
				}
			}// if sphere intersects plane
		}//endfor

		return hit;
	}//endFunction

}//endclass

/**
* private class to hold collision triangle data
*/
class TriData
{
	public var ax:Number;		// tri vertex a
	public var ay:Number;
	public var az:Number;
	public var bx:Number;		// tri vertex b
	public var by:Number;
	public var bz:Number;
	public var cx:Number;		// tri vertex c
	public var cy:Number;
	public var cz:Number;

	public var nx:Number;		// normalized triangle normal, by determinant
	public var ny:Number;
	public var nz:Number;


	public function TriData(ax:Number,ay:Number,az:Number,
							bx:Number,by:Number,bz:Number,
							cx:Number,cy:Number,cz:Number) : void
	{
		this.ax = ax;
		this.ay = ay;
		this.az = az;
		this.bx = bx;
		this.by = by;
		this.bz = bz;
		this.cx = cx;
		this.cy = cy;
		this.cz = cz;

		var px:Number = bx - ax;		// tri side vector from a to b
		var py:Number = by - ay;		// tri side vector from a to b
		var pz:Number = bz - az;		// tri side vector from a to b

		var qx:Number = cx - ax;		// tri side vector from a to c
		var qy:Number = cy - ay;		// tri side vector from a to c
		var qz:Number = cz - az;		// tri side vector from a to c

		// normal by determinant Tn
		nx = py*qz-pz*qy;				//	normal x for the triangle
		ny = pz*qx-px*qz;				//	normal y for the triangle
		nz = px*qy-py*qx;				//	normal z for the triangle
		var nl:Number = Math.sqrt(nx * nx + ny * ny + nz * nz);
		nx /= nl;
		ny /= nl;
		nz /= nl;
	}//endConstructor

	/**
	* given line L(o:pt,v:vect) returns its intersection on triangle T(a:pt,b:pt,c:pt)
	*/
	public function lineIntersection(	lox:Number,loy:Number,loz:Number,
										lvx:Number,lvy:Number,lvz:Number,
										chkInTri:Boolean=true) : VertexData
	{
		var px:Number = bx - ax;		// tri side vector from a to b
		var py:Number = by - ay;		// tri side vector from a to b
		var pz:Number = bz - az;		// tri side vector from a to b

		var qx:Number = cx - ax;		// tri side vector from a to c
		var qy:Number = cy - ay;		// tri side vector from a to c
		var qz:Number = cz - az;		// tri side vector from a to c

		// let X be the intersection point, then equation of triangle plane Tn.(X-Ta) = 0
		// but X = Lo+Lv*k   =>   Tn.(Lo+Lv*k-Ta) = 0    =>   Tn.Lv*k + Tn.(Lo-Ta) = 0
		// k = (Ta-Lo).Tn/Lv.Tn
		// denom!=0 => there is intersection in the plane of tri

		var denom:Number = lvx*nx+lvy*ny+lvz*nz;
		if (denom==0)	return null;		// return no intersection or line in plane...

		var num:Number = (nx*(ax-lox) + ny*(ay-loy) + nz*(az-loz));
		var k:Number = num/denom;
		if (chkInTri && (k<0 || k>1)) return null;	// return no segment intersection

		var ix:Number = lox+lvx*k - ax;		// vector to segment intersection on triangle plane
		var iy:Number = loy+lvy*k - ay;		// vector to segment intersection on triangle plane
		var iz:Number = loz+lvz*k - az;		// vector to segment intersection on triangle plane

		// find scalars along triangle sides P and Q s.t. sP+tQ = I
		// s = (p.q)(w.q)-(q.q)(w.p)/(p.q)(p.q)-(p.p)(q.q)
		// t = (p.q)(w.p)-(p.p)(w.q)/(p.q)(p.q)-(p.p)(q.q)
		var p_p:Number = px*px+py*py+pz*pz;
		var q_q:Number = qx*qx+qy*qy+qz*qz;
		var p_q:Number = px*qx+py*qy+pz*qz;
		var w_p:Number = ix*px+iy*py+iz*pz;
		var w_q:Number = ix*qx+iy*qy+iz*qz;

		denom = p_q*p_q - p_p*q_q;
		var s:Number = (p_q*w_q - q_q*w_p)/denom;
		var t:Number = (p_q*w_p - p_p*w_q)/denom;

		if (chkInTri && (s<0 || t<0 || s+t>1)) return null;	// return intersection outside triangle

		return new VertexData(	ax+s*px+t*qx,	// return intersection point within tri
								ay+s*py+t*qy,	// return intersection point within tri
								az+s*pz+t*qz,	// return intersection point within tri
								nx,ny,nz);		// triangle normal
	}//endfunction

	public function toString():String
	{
		return "{("+int(ax*100)/100+","+int(ay*100)/100+","+int(az*100)/100+")("+int(bx*100)/100+","+int(by*100)/100+","+int(bz*100)/100+")("+int(cx*100)/100+","+int(cy*100)/100+","+int(cz*100)/100+")}";
	}
}//endclass

/**
 * private class to hold ambient rgb, spec strength and hardness of a mesh
 */
class Material
{
	public var ambR:Number = 0.5;
	public var ambG:Number = 0.5;
	public var ambB:Number = 0.5;
	public var fogR:Number = 0;
	public var fogG:Number = 0;
	public var fogB:Number = 0;
	public var fogFar:Number = 0;
	public var specStr:Number = 0.5;
	public var specHard:Number = 0.5;

	public function clone():Material
	{
		var lum:Material = new Material();
		lum.ambR = ambR;
		lum.ambG = ambG;
		lum.ambB = ambB;
		lum.fogR = fogR;
		lum.fogG = fogG;
		lum.fogB = fogB;
		lum.fogFar = fogFar;
		lum.specStr = specStr;
		lum.specHard = specHard;
		return lum;
	}//endfunction
}//endclass
