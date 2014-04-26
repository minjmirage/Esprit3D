﻿package core3D
{
	import flash.display.Bitmap;
	import flash.display.BitmapData;
	import flash.display.Loader;
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.geom.Point;
	import flash.geom.Rectangle;
	import flash.geom.Vector3D;
	import flash.net.FileReference;
	import flash.net.URLLoader;
	import flash.net.URLRequest;
	import flash.net.registerClassAlias;
	import flash.text.TextField;
	import flash.utils.ByteArray;
	import flash.utils.getTimer;
	
	/**
	* Integrated MD5 format parser and animator class with GPU skinning enabled
	* Author: Lin Minjiang	2012/03/05  updated
	*/
	public class MD5Animae
	{
		public var skin:Mesh = null;				// mesh displaying this animated model
		public var boneTrace:Mesh = null;			// mesh displaying the bones structure
		public var maxBonesPerVertex:int=0;			// 
		public var BindPoseRect:VertexData=null;	// bind pose bounding rectangle vx,vy,vz (min)  nx,ny,nz (max)
		
		public var GPUSkinning:Boolean = false;		// GPU SKINNING FLAG
		
		public var md5Skins:Vector.<MD5Animae> = null;	// other skins to swap for same set of anims
		
		public static var debugTf:TextField = null;
		
		protected var BindPoseData:Array = null;	// [jointName,parentIdx,jointData, ...] where jointData: vx,vy,vz=position nx,ny,nz=quaternion, holds parent child relationship
		protected var MeshesData:Array = null;		// [mT,mV,mW...]
		protected var Animations:Array = null;		// [animId,frameRate,Frames,...]
													// where frameData = [px,py,pz,xOrient,yOrient,zOrient,...] in bone order
				
		private var currentPoseData:Vector.<VertexData> = null;	// current pose data [{px,py,pz,xOrient,yOrient,zOrient},...] in bone order
		private var M:Vector.<Mesh> = null;			// vector of meshes in skin
		
		private var _V:Vector.<VertexData> = null;	// working vector used in generateSkin
		
		// ----- verlet integration ragdoll physics
		public var VPJPs:Vector.<Vector3D> = null;		// verlet previous joint positions
		
		/**
		* Expects parameters of the following formats
		* Jdata:Array = [jointName,parentIdx,jointData, ...] where jointData: vx,vy,vz=position nx,ny,nz=quaternion 
		* Mdata:Array = [mT,mV,mW,...]								// meshes data
		* where 
		*   mT:Vector.<uint> = [vertIndex1,vertIndex2,vertIndex3,...]			// triangles def
		*   mV:Vector.<Number> = [texU,texV,weightIndex,weightElem,...]			// vertices def
		*   mW:Vector.<VertexData> = [{vx=xPos,vy=yPos,vz=zPos,w=weightValue,idx=jointIndex},...]	// weights def
		*/
		public function MD5Animae(Jdata:Array,Mdata:Array,genNormals:Boolean=true) : void
		{
			skin = new Mesh();
			BindPoseData = Jdata;
			MeshesData = Mdata;
			Animations = [];
			
			// precreate number of Mesh equal to number if submeshes in model
			M = new Vector.<Mesh>();
			var defaTex:BitmapData = new BitmapData(1,1,true,0xAAFFFFFF);
			while (M.length<=MeshesData.length/3)
			{
				M.push(new Mesh());
				//M[M.length-1].transform = new Matrix4x4().translate((M.length-1)*10,0,0);	// debug
				M[M.length-1].setTexture(defaTex);
				M[M.length-1].setAmbient(0.3,0.3,0.3);
				M[M.length-1].setSpecular(0.1);
				skin.addChild(M[M.length-1]);
			}
			
			if (BindPoseData!=null && MeshesData!=null)	
			{
				// ----- create bind pose frame data ----------------
				currentPoseData = new Vector.<VertexData>();
				for (var i:int=0; i<BindPoseData.length; i+=3)
					currentPoseData.push(BindPoseData[i+2]);
				
				// ----- calculate normals --------------------------
				if (genNormals) 
				{
					BindPoseRect = preGenerateNormals();		// only do once is enough
					maxBonesPerVertex = BindPoseRect.idx;
				}
				
				// ----- prep for GPU skinning or CPU ---------------
				if (BindPoseData.length<=61*3)	GPUSkinning = true;	
				if (GPUSkinning)
				{
					GPUSkinningPrep();
					GPUSkinningUpdateJoints();
				}
				else
					generateSkinPose();
			}
		}//endfunction
		
		/**
		* adds a new md5mesh file to this 
		*/ 
		public function addMesh(dat:String):void
		{
			var md5a:MD5Animae = MD5Animae.parseMesh(dat);
			if (md5a==null) return;
			if (md5Skins==null)
			{
				md5Skins = new Vector.<MD5Animae>();
				md5Skins.push(new MD5Animae(BindPoseData,MeshesData));	// add the default skin first
			}
			md5Skins.push(md5a);	// add newly parsed skin
		}//endfunction
		
		/**
		* adds a new md5mesh file to this 
		*/ 
		public function addMeshFromFile(url:String,fn:Function=null):void
		{
			MD5Animae.loadModel(url,function(md5a:MD5Animae):void
			{
				if (md5Skins==null)
				{
					md5Skins = new Vector.<MD5Animae>();
					md5Skins.push(new MD5Animae(BindPoseData,MeshesData));	// add the default skin first
					md5Skins[0].skin = skin.clone();
				}
				md5Skins.push(md5a);	// add newly parsed skin
			});
		}//endfunction
		
		/**
		* switch to already loaded mesh for next render
		*/ 
		public function switchMesh(i:uint):void
		{
			if (md5Skins==null)	return;
			i = i%md5Skins.length;
			var nSkin:MD5Animae = md5Skins[i];
			
			MeshesData = nSkin.MeshesData;
			
			while (M.length>0)
			{
				skin.removeChild(M[0]);
				M.shift();
			}
			for (i=0; i<nSkin.M.length; i++)
			{
				M.push(nSkin.M[i]);
				skin.addChild(nSkin.M[i]);
			}
			if (nSkin.BindPoseRect!=null)
			{
				BindPoseRect = nSkin.BindPoseRect;
				maxBonesPerVertex = BindPoseRect.idx;
			}
		}//endfunction
		
		/**
		* returns a shallow clone having the same geometry, textures and existing animations
		*/
		public function clone() : MD5Animae
		{
			var anim:MD5Animae = new MD5Animae(BindPoseData,MeshesData);
			anim.Animations = Animations;
			anim.skin = skin.clone();
			return anim;
		}//endfunction
		
		/**
		* NOT TESTED!
		*/
		public function saveAsAmf2(fileName:String="data") : void
		{
			function w_mT(mT:Vector.<uint>):void
			{
				ba.writeShort(mT.length);
				var n:int=mT.length;
				for (var i:int=0; i<n; i++) ba.writeShort(mT[i]);
			}
			function w_mV(mV:Vector.<Number>):void
			{
				ba.writeShort(mV.length);
				var n:int=mV.length;
				for (var i:int=0; i<n; i+=4) 
				{
					ba.writeFloat(mV[i+0]);
					ba.writeFloat(mV[i+1]);
					ba.writeShort(mV[i+2]);
					ba.writeShort(mV[i+3]);
				}
			}
			function w_mW(mW:Vector.<VertexData>):void
			{
				ba.writeShort(mW.length);
				var n:int=mW.length;
				for (var i:int=0; i<n; i++) 
				{
					var vd:VertexData = mW[i];
					ba.writeFloat(vd.vx);	// posn
					ba.writeFloat(vd.vy);
					ba.writeFloat(vd.vz);
					ba.writeFloat(vd.nx);	// normal
					ba.writeFloat(vd.ny);
					ba.writeFloat(vd.nz);
					ba.writeFloat(vd.w);	// weight
					ba.writeShort(vd.idx);	// bone idx
				}
			}
			
			var ba:ByteArray = new ByteArray();
			
			if (md5Skins!=null) ba.writeShort(md5Skins.length-1);
			else				ba.writeObject(0);
			
			ba.writeObject(BindPoseData);
			ba.writeObject(MeshesData);
			ba.writeObject(Animations);
			if (md5Skins!=null)
				for (var i:int=1; i<md5Skins.length; i++)
					ba.writeObject(md5Skins[i].MeshesData);	// write other swappable skin meshes
			var MyFile:FileReference = new FileReference();
			MyFile.save(ba,fileName+".amf");
		}//endfunction
		
		/**
		* outputs this MD5Animae data as byte array file
		*/
		public function saveAsAmf(fileName:String="data") : void
		{
			var ba:ByteArray = new ByteArray();
			
			if (md5Skins!=null) ba.writeObject((md5Skins.length-1)+"");
			else				ba.writeObject("0");
			registerClassAlias("VertexDataAlias", VertexData);
			ba.writeObject(BindPoseData);
			ba.writeObject(MeshesData);
			ba.writeObject(Animations);
			if (md5Skins!=null)
				for (var i:int=1; i<md5Skins.length; i++)
					ba.writeObject(md5Skins[i].MeshesData);	// write other swappable skin meshes
			var MyFile:FileReference = new FileReference();
			MyFile.save(ba,fileName+".amf");
		}//endfunction
		
		/**
		* parses MD5Animae data in AMF format from given file url 
		*/
		public static function loadAmf(url:String,fn:Function=null) : void
		{
			var ldr:URLLoader = new URLLoader();
			ldr.dataFormat = "binary";
			var req:URLRequest = new URLRequest(url);
			function completeHandler(e:Event):void 
			{
				if (fn!=null)	fn(parseAmf(ldr.data));
			}
			ldr.addEventListener(Event.COMPLETE, completeHandler);
			ldr.load(req);
		}//endfunction		
		
		/**
		* returns MD5Animae from byte array data
		*/
		public static function parseAmf(ba:ByteArray) : MD5Animae
		{
			registerClassAlias("VertexDataAlias", VertexData);
			ba.position = 0;
			var numOtherSkins:int = Number(ba.readObject()+"");
			var anim:MD5Animae = new MD5Animae(ba.readObject(),ba.readObject(),false);
			anim.Animations = ba.readObject();
			
			while (numOtherSkins>0)
			{
				var meshesData:Array = ba.readObject();
				if (anim.md5Skins==null)
				{
					anim.md5Skins = new Vector.<MD5Animae>();
					anim.md5Skins.push(new MD5Animae(anim.BindPoseData,anim.MeshesData,false));	// add the default skin first
				}
				anim.md5Skins.push(new MD5Animae(anim.BindPoseData,meshesData,false));	// add newly parsed skin
				numOtherSkins--;
			}
			return anim;
		}//endfunction
		
		/**
		* precalculate weight normals and add to weights data, makes GPU skinning normals calculations possible, 
		* returns bounding rectangle data (vx,vy,vz,nx,ny,nz) and max bones per ver vertex (idx)
		*/
		private function preGenerateNormals() : VertexData
		{
			var rect:VertexData = 
			new VertexData(	Number.MAX_VALUE,Number.MAX_VALUE,Number.MAX_VALUE,	// bounding min
							Number.MIN_VALUE,Number.MIN_VALUE,Number.MIN_VALUE,	// bounding max
							0,0,0,
							0);		// bones count
			
			var JTs:Vector.<Matrix4x4> = getTransforms(currentPoseData);	// get skeleton pose joint transforms
			
			for (var m:uint=0; m<MeshesData.length; m+=3)	// for each mesh
			{
				var mT:Vector.<uint> = MeshesData[m+0];
				var mV:Vector.<Number> = MeshesData[m+1];
				var mW:Vector.<VertexData> = MeshesData[m+2];
				
				// ----- create working data vector if not exist
				if (_V==null) _V = new Vector.<VertexData>();	// vertex results vector
				for (var i:int=_V.length; i<mV.length/4; i++)	_V.push(new VertexData());
				
				// ----- calculate vertices positions -------------------------
				for (var v:uint=0; v<mV.length; v+=4)	// for each vertex
				{
					var widx:int = mV[v+2];			// mW index
					var widxend:int = widx+mV[v+3];	// mW end index exclusive
					var vx:Number = 0;
					var vy:Number = 0;
					var vz:Number = 0;
					for (var w:uint=widx; w<widxend; w++)
					{
						var wD:VertexData = mW[w];		// weight data 
						var weight:Number = wD.w;		// weight value
						var px:Number = wD.vx;			// weight posn
						var py:Number = wD.vy;			// weight posn
						var pz:Number = wD.vz;			// weight posn
						var jT:Matrix4x4 = JTs[wD.idx];	//joint transform
						vx+= weight*(jT.aa*px + jT.ab*py + jT.ac*pz + jT.ad);
						vy+= weight*(jT.ba*px + jT.bb*py + jT.bc*pz + jT.bd);
						vz+= weight*(jT.ca*px + jT.cb*py + jT.cc*pz + jT.cd);
					}
					
					// ----- store calculated vertex position
					var vd:VertexData = _V[v/4];
					vd.vx=vx; vd.vy=vy; vd.vz=vz; 		// set position data
					vd.nx=0; vd.ny=0; vd.nz=0; 			// reset normals
					vd.u=mV[v+0]; vd.v=mV[v+1];			// set UV data
					
					// ----- update min max values
					if (rect.vx>vx)	rect.vx=vx;
					if (rect.vy>vy)	rect.vy=vy;
					if (rect.vz>vz)	rect.vz=vz;
					if (rect.nx<vx)	rect.nx=vx;
					if (rect.ny<vy)	rect.ny=vy;
					if (rect.nz<vz)	rect.nz=vz;
					if (rect.idx<mV[v+3]) rect.idx=mV[v+3];
				}//endfor each vertex
				
				var _T:Vector.<Vector3D> = new Vector.<Vector3D>();		// vector to store tangent infos
				for (i=_T.length; i<mV.length/4; i++)	_T.push(new Vector3D());
				
				// ----- calculate normals and tangents -----------------------
				for (var t:uint=0; t<mT.length; t+=3)	// going through each triangle
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
					
					// ----- calculate tangent basis for normal mapping -------
					var i0:uint = mT[t];
					var i1:uint = mT[t+1];
					var i2:uint = mT[t+2];
					
					var pax:Number = _V[i1].u - _V[i0].u;
					var ax:Number = pax;			
					do {
						var tmp:uint=i0; i0=i1; i1=i2; i2=tmp;	
						ax = _V[i1].u - _V[i0].u;
					} while (ax*ax>pax*pax);
					tmp=i2; i2=i1; i1=i0; i0=tmp;
					
					var va:VertexData = _V[i0];	// vertex A
					var vb:VertexData = _V[i1];	// vertex B
					var vc:VertexData = _V[i2];	// vertex C
					
					ax				= vb.u - va.u;
					var	ay:Number 	= vb.v - va.v;
					var bx:Number 	= vc.u - va.u;
					var by:Number 	= vc.v - va.v;
					var q:Number = 1/(by-ay*bx/ax);	// solns for tangent basis
					var p:Number = -q*bx/ax;
					
					var tpx:Number = vb.vx - va.vx;
					var tpy:Number = vb.vy - va.vy;
					var tpz:Number = vb.vz - va.vz;
					var tqx:Number = vc.vx - va.vx;
					var tqy:Number = vc.vy - va.vy;
					var tqz:Number = vc.vz - va.vz;
					
					var tt:Vector3D = null;	// store tangent basis in _T
					tt=_T[i0]; tt.x+=p*tpx+q*tqx; tt.y+=p*tpy+q*tqy; tt.z+=p*tpz+q*tqz;
					tt=_T[i1]; tt.x+=p*tpx+q*tqx; tt.y+=p*tpy+q*tqy; tt.z+=p*tpz+q*tqz;
					tt=_T[i2]; tt.x+=p*tpx+q*tqx; tt.y+=p*tpy+q*tqy; tt.z+=p*tpz+q*tqz;
					
					// ----- calculate vertex normals -------------------------
					// normal by determinant
					var nx:Number = tpy*tqz-tpz*tqy;	//	unit normal x for the triangle
					var ny:Number = tpz*tqx-tpx*tqz;	//	unit normal y for the triangle
					var nz:Number = tpx*tqy-tpy*tqx;	//	unit normal z for the triangle
					var nl:Number = Math.sqrt(nx*nx+ny*ny+nz*nz);
					nx/=nl; ny/=nl; nz/=nl;
					
					//----- add normals values to vertex ----------------------
					va.nx += nx;	va.ny += ny;	va.nz += nz;
					vb.nx += nx;	vb.ny += ny;	vb.nz += nz;
					vc.nx += nx;	vc.ny += ny;	vc.nz += nz;
				}//endfor each tri
				
				// ----- vertices to share normals if in same position --------
				for (i=0; i<_V.length; i++)	// to fix normals at the seams
					for (v=i; v<_V.length; v++)
				{
					va = _V[i];
					vb = _V[v];
					vx = va.vx-vb.vx;
					vy = va.vy-vb.vy;
					vz = va.vz-vb.vz;
					if (vx*vx+vy*vy+vz*vz<=0.000000001)
					{
						vx = va.nx;		// add the normal values for va and vb
						vy = va.ny;
						vz = va.nz;
						va.nx+=vb.nx;
						va.ny+=vb.ny;
						va.nz+=vb.nz;
						vb.nx+=vx;
						vb.ny+=vy;
						vb.nz+=vz;
					}
				}
				
				// ----- normalize normals ------------------------------------
				for (v=0; v<_V.length; v++)
				{
					va = _V[v];
					nl = Math.sqrt(va.nx*va.nx+va.ny*va.ny+va.nz*va.nz);
					if (nl>0)	{va.nx/=nl; va.ny/=nl; va.nz/=nl;}
					if (_T[v].length > 0) 
					{
						_T[v] = new Vector3D(va.nx, va.ny, va.nz).crossProduct(_T[v]);
						_T[v].scaleBy(-1/_T[v].length);
					}
				}//endfor each calculated vertex
				
				// ----- add normals data to weights data ---------------------
				for (v=0; v<mV.length; v+=4)		// for each vertex
				{
					va = _V[v/4];				// vertexData with precalculated normal 
					tt = _T[v/4];				// vector3D with precalculated tangent
					widx = mV[v+2];				// mW index
					widxend = widx+mV[v+3];		// mW end index exclusive
					for (w=widx; w<widxend; w++)
					{
						wD = mW[w];				// weight data 
						jT = JTs[wD.idx];		//joint transform
						var ijT:Matrix4x4 = jT.inverse();	// inverse transform 
						wD.nx = ijT.aa*va.nx + ijT.ab*va.ny + ijT.ac*va.nz;	// weight normal
						wD.ny = ijT.ba*va.nx + ijT.bb*va.ny + ijT.bc*va.nz;
						wD.nz = ijT.ca*va.nx + ijT.cb*va.ny + ijT.cc*va.nz;
						wD.tx = ijT.aa*tt.x + ijT.ab*tt.y + ijT.ac*tt.z;	// weight tangent
						wD.ty = ijT.ba*tt.x + ijT.bb*tt.y + ijT.bc*tt.z;
						wD.tz = ijT.ca*tt.x + ijT.cb*tt.y + ijT.cc*tt.z;
					}
				}//endfor
			}//endfor mesh
			
			return rect;
		}//endfunction
				
		/**
		* Formats and writes weights data to mesh for GPU skinning ,
		* Max 61 joints supportable for GPU skinning 
		*/
		private function GPUSkinningPrep() : void
		{
			//preGenerateNormals();
			// inputs:		va0 = texU,texV	 					// UV for this point
			//				va1 = wnx,wny,wnz,transIdx 			// weight normal 1
			//				va2 = wtx,wty,wtz,0 				// weight tangent 1
			//				va3 = wvx,wvy,wvz,transIdx+weight 	// weight vertex 1
			//				va4 = wvx,wvy,wvz,transIdx+weight  	// weight vertex 2
			//				va5 = wvx,wvy,wvz,transIdx+weight  	// weight vertex 3
			//				va6 = wvx,wvy,wvz,transIdx+weight 	// weight vertex 4
			
			function weightCompFn(v1:VertexData,v2:VertexData) : int	{return v2.w*1000-v1.w*1000;}
			
			var idxOff:int = 5;		// vertex constants register offset
						
			// ----- create GPU weights data for skinning vertex shader ---
			for (var m:uint=0; m<MeshesData.length; m+=3)	// for each mesh
			{
				var mT:Vector.<uint> = MeshesData[m+0];
				var mV:Vector.<Number> = MeshesData[m+1];
				var mW:Vector.<VertexData> = MeshesData[m+2];
								
				var VB:Vector.<Number> = new Vector.<Number>();	// vertex buffer data
				
				for (var v:uint=0; v<mV.length; v+=4)	// for each vertex
				{
					var widx:int = mV[v+2];				// mW index
					var nw:int = mV[v+3];				// number of weights
					//if (debugTf!=null) debugTf.appendText("v="+v+" widx:"+widx+" nw:"+nw+"\n");
					
					if (nw>0)	// amazingly it occurs sometimes...
					{
						// ----- sort weights in decending order
						var WDs:Array = new Array();
						for (var i:uint=widx; i<widx+nw; i++)	WDs.push(mW[i]);
						WDs = WDs.sort(weightCompFn);		// sorted weights data
					
						/*
						// ----- calculate to normalize weights
						var weightsSum:Number = 0;
						for (i=0; i<4 && i<WDs.length; i++)
							weightsSum = WDs[i].w;
						*/
						// ----- write data to result vector
						VB.push(mV[v+0],mV[v+1]);				// UV data
						var wD:VertexData = WDs[0];				// weight data 
						VB.push(wD.nx,wD.ny,wD.nz);				// push weight1 normal
						VB.push(idxOff+Math.min(wD.idx,61)*2);	// push transformIdx
						VB.push(wD.tx,wD.ty,wD.tz);				// push weight1 tangent
						VB.push(0);								// push transformIdx
						// ----- layout weights data in order
						if (nw>4) nw=4;						// restrict to 4 weights
						for (i=0; i<nw; i++)
						{
							wD = WDs[i];					// weight data 
							VB.push(wD.vx,wD.vy,wD.vz);		// push weight position
							VB.push(idxOff+Math.min(wD.idx,61)*2+Math.min(0.99999,wD.w));	// push transformIdx+weight
						}
						
						// ----- pad rest with 0s
						for (i=nw; i<4; i++)
						{
							VB.push(0,0,0);					// push 0,0,0 for weight position
							VB.push(0);						// push 0 for transform idx+weight
						}
					}
				}//endfor v
				
				M[m/3].setSkinning(VB,mT);			// pass vertices and indices data directly to mesh
			}//endfor m
		}//endfunction
		
		/**
		* Max of 61 joints supportable for GPU skinning
		* updates meshes with new joints orientations and positions
		*/
		private function GPUSkinningUpdateJoints(frameData:Vector.<VertexData>=null) : void
		{
			var i:int=0;
			
			// ----- if not given frame data, fallback on bindpose data
			if (frameData==null)	frameData = currentPoseData;	// existing pose data
			
			// ----- set joints data to correct format and push to mesh
			var n:uint = Math.min(frameData.length,61);
			var R:Vector.<Number> = new Vector.<Number>();
			for (i=0; i<n; i++)	
			{
				var jd:VertexData = frameData[i];	// joint data
				R.push(-jd.nx,-jd.ny,-jd.nz,0);		// quaternion orientation data
				R.push( jd.vx, jd.vy, jd.vz,0);		// tx,ty,tx,0	translation data
			}
			for (var m:uint=0; m<M.length; m++)		M[m].jointsData = R;
		}//endfunction
		
		/**
		* given frameData : [{px,py,pz, nx,ny,nz},...] where (px,py,pz)=posn, (nx,ny,nz)=quat in object space
		* update mesh geometry to reflect skin in pose specified by frameData
		* returns mesh containing skin geometry
		*/
		public function generateSkinPose(frameData:Vector.<VertexData>=null) : Mesh
		{
			if (GPUSkinning)	return skin;	// prevent GPU prep data being overridden
			
			var timee:int = getTimer();
			
			if (frameData==null)	frameData=currentPoseData;		// fallback on existing pose data
			var JTs:Vector.<Matrix4x4> = getTransforms(frameData);	// get skeleton pose joint transforms
									
			for (var m:uint=0; m<MeshesData.length; m+=3)	// for each mesh
			{
				var mT:Vector.<uint> = MeshesData[m+0];
				var mV:Vector.<Number> = MeshesData[m+1];
				var mW:Vector.<VertexData> = MeshesData[m+2]; 
			
				// ----- create working data vector if not exist
				if (_V==null) _V = new Vector.<VertexData>();	// vertex results vector
				for (var i:int=_V.length; i<mV.length/4; i++)	_V.push(new VertexData());
				
				// ----- calculate vertices positions
				for (var v:uint=0; v<mV.length; v+=4)	// for each vertex
				{
					var widx:int = mV[v+2];			// mW index
					var widxend:int = widx+mV[v+3];	// mW end index exclusive
					var vx:Number = 0;				// vertex value to accumulate
					var vy:Number = 0;
					var vz:Number = 0;
					var nx:Number = 0;				// normal value to accumulate
					var ny:Number = 0;
					var nz:Number = 0;
					var tx:Number = 0;				// tangent value to accumulate
					var ty:Number = 0;
					var tz:Number = 0;
					for (var w:uint=widx; w<widxend; w++)
					{
						var wD:VertexData = mW[w];	// weight data 
						var weight:Number = wD.w;	// weight value
						var wpx:Number = wD.vx;		// weight posn
						var wpy:Number = wD.vy;		// weight posn
						var wpz:Number = wD.vz;		// weight posn
						var wnx:Number = wD.nx;
						var wny:Number = wD.ny;
						var wtz:Number = wD.tz;
						var wtx:Number = wD.tx;
						var wty:Number = wD.ty;
						var wnz:Number = wD.nz;var jT:Matrix4x4 = JTs[wD.idx];	//joint transform
						
						vx+= weight*(jT.aa*wpx + jT.ab*wpy + jT.ac*wpz + jT.ad);
						vy+= weight*(jT.ba*wpx + jT.bb*wpy + jT.bc*wpz + jT.bd);
						vz+= weight*(jT.ca*wpx + jT.cb*wpy + jT.cc*wpz + jT.cd);
						if (nx==0 && ny==0 && nz==0)
						{
							nx = jT.aa*wnx + jT.ab*wny + jT.ac*wnz;
							ny = jT.ba*wnx + jT.bb*wny + jT.bc*wnz;
							nz = jT.ca*wnx + jT.cb*wny + jT.cc*wnz;
						}
						if (tx==0 && ty==0 && tz==0)
						{
							tx = jT.aa*wtx + jT.ab*wty + jT.ac*wtz;
							ty = jT.ba*wtx + jT.bb*wty + jT.bc*wtz;
							tz = jT.ca*wtx + jT.cb*wty + jT.cc*wtz;
						}
					}
					
					// ----- store calculated vertex position
					var vd:VertexData = _V[v/4];
					vd.vx=vx; vd.vy=vy; vd.vz=vz; 	// set position data
					vd.nx=nx; vd.ny=ny; vd.nz=nz;	// set normal data
					vd.tx=tx; vd.ty=ty; vd.tz=tz;	// set tangent data
					vd.u=mV[v+0]; vd.v=mV[v+1];		// set UV data
				}//endfor each vertex
								
				if (debugTf!=null) debugTf.appendText("Tris="+mT.length/3+"  Vertices="+mV.length/4+"  Weights="+mW.length);
				
				// ----- write out data in [vx,vy,vz,nx,ny,nz,tx,ty,tz,u,v, ....] format in original vertices order
				var V:Vector.<Number> = M[m/3].vertData;	// reusing mesh vector...	
				if (V==null)	V = new Vector.<Number>();
				while (V.length>_V.length*11)	V.pop();
				for (v=0; v<_V.length; v++)			// for each vertex in triangle
				{
					var vt:VertexData = _V[v];
					var idx:int = v*11;
					V[idx++]=vt.vx;	V[idx++]=vt.vy;	V[idx++]=vt.vz;
					V[idx++]=vt.nx;	V[idx++]=vt.ny;	V[idx++]=vt.nz;
					V[idx++]=vt.tx;	V[idx++]=vt.ty;	V[idx++]=vt.tz;
					V[idx++]=vt.u;	V[idx++]=vt.v;
				}//endfor each triangle
				
				if (debugTf!=null) debugTf.appendText("  OUTPUT : V.length="+V.length+" mT.length="+mT.length+"\n");
				M[m/3].setGeometry(V,mT,true);		// pass vertices and indices data directly to mesh
			}//endfor each mesh						// so as not to duplicate vertices 3x
			if (debugTf!=null) debugTf.appendText("TimeLapsed = "+(getTimer()-timee)+"***\n");
			return skin;
		}//endfunction
		
		/**
		* given frameData : [{px,py,pz, nx,ny,nz},...] where (px,py,pz)=posn, (nx,ny,nz)=quat in object space
		* update bones traces to reflect bones positions in pose specified by frameData
		* returns mesh containing bone traces
		*/
		public function generateSkeletonPose(frameData:Vector.<VertexData>=null) : Mesh
		{
			if (frameData==null)	frameData=currentPoseData;		// fallback on existing pose data
			var JTs:Vector.<Matrix4x4> = getTransforms(frameData);	// get skeleton pose joint transforms
			
			if (boneTrace==null) boneTrace = new Mesh();
			var n:int = JTs.length;
			var i:int=0;	
			var pidx:int=0;	
			var dx:Number=0; var dy:Number=0; var dz:Number=0;
			var T:Matrix4x4=null;
			var pT:Matrix4x4=null;
			
			//var redBmd:BitmapData = new BitmapData(1,1,false,0xFFFF0000);
			// ----- create correct number of stick joints ----------
			while (boneTrace.childMeshes.length<n)	boneTrace.addChild(Mesh.createBone(1));
			
			// ----- find average bone length -----------------------
			var bl:Number = 0;
			var bc:int=0;
			for (i=0; i<n; i++)
			{
				pidx =BindPoseData[i*3+1];
				if (pidx>-1)
				{
					T = JTs[i];			// current joint trans
					pT = JTs[pidx];		// parent joint trans 
					dx = T.ad-pT.ad;
					dy = T.bd-pT.bd;
					dz = T.cd-pT.cd;
					bl+=Math.sqrt(dx*dx+dy*dy+dz*dz);
					bc++;
				}
			}//endfor
			bl/=bc;
			
			if (debugTf!=null)
				debugTf.appendText("n="+n+"   boneTrace.childMeshes.length="+boneTrace.childMeshes.length+"\n");
			// ----- shift joints to current pose -------------------
			for (i=0; i<n; i++)
			{
				// ----- add bone shape connecting from current joint to parent joint
				T = JTs[i];			// current joint trans
				var stick:Mesh = boneTrace.childMeshes[i];
				stick.transform = T.mult(new Matrix4x4().scale(bl,bl,bl).rotX(-Math.PI/2));
								
				pidx =BindPoseData[i*3+1];
				if (pidx>-1)
				{
					pT = JTs[pidx];		// parent joint trans 
					dx = T.ad-pT.ad;
					dy = T.bd-pT.bd;
					dz = T.cd-pT.cd;
					var dl:Number = Math.sqrt(dx*dx+dy*dy+dz*dz);			
					var pV:Vector3D = pT.rotateVector(new Vector3D(0,1,0));	// parent joint direction
					pV.normalize();
					if (dx/dl*pV.x+dy/dl*pV.y+dz/dl*pV.z > 0.9999)	// if parent joint direction points to child
					{
						stick = boneTrace.childMeshes[pidx];		// place and lengthen bone to connect with child
						stick.transform = (new Matrix4x4()).scale(dl,dl,dl).rotFromTo(0,0,1,dx,dy,dz).translate(pT.ad,pT.bd,pT.cd);
					}
				}
			}//endfor
			
			boneTrace.transform = skin.transform;
			return boneTrace;
		}//endfunction
				
		/**
		* given frameData: [{vx,vy,vz, nx,ny,nz},...] where (vx,vy,vz)=posn, (nx,ny,nz)=quat  in joints space
		* returns [{vx,vy,vz, nx,ny,nz},...] where (vx,vy,vz)=posn, (nx,ny,nz)=quat  converted into object space
		*/
		private function jointOrientationsToObjectSpace(frameData:Vector.<VertexData>) : Vector.<VertexData>
		{
			var n:int = Math.min(BindPoseData.length/3,frameData.length);
			
			var R:Vector.<VertexData> = new Vector.<VertexData>();
			for (var i:int=0; i<n; i++)
			{
				var jname:String = BindPoseData[i*3+0];
				var pidx:int = int(BindPoseData[i*3+1]);
				
				// ----- position parameters
				var jt:VertexData = frameData[i];	// current joint
				var tx:Number = jt.vx;
				var ty:Number = jt.vy;
				var tz:Number = jt.vz;
				
				// ----- quarternion parameters
				var b:Number = jt.nx;
				var c:Number = jt.ny;
				var d:Number = jt.nz;
				var a:Number = 1-b*b-c*c-d*d;
				if (a<0) {a=Math.sqrt(b*b+c*c+d*d); b/=a; c/=a; d/=a; a=0;}	
				a =-Math.sqrt(a);
				
				if (pidx>-1)
				{
					var pjt:VertexData = R[pidx];	// parent joint
					var pb:Number = pjt.nx;
					var pc:Number = pjt.ny;
					var pd:Number = pjt.nz;
					var pa:Number = 1-pb*pb-pc*pc-pd*pd;
					if (pa<0) {pa=Math.sqrt(pb*pb+pc*pc+pd*pd); pb/=pa; pc/=pa; pd/=pa; pa=0;}	
					pa =-Math.sqrt(pa);
					
					// get final quaternion
					var qc:Vector3D =  quatMult(pb,pc,pd,pa, b,c,d,a);
					
					// parent quat rotate tx,ty,tz
					var pt:Vector3D = quatMult(pb,pc,pd,pa, tx,ty,tz,0);
					pt = quatMult(pt.x,pt.y,pt.z,pt.w, -pb,-pc,-pd,pa);
					
					// override
					tx = pjt.vx + pt.x;
					ty = pjt.vy + pt.y;
					tz = pjt.vz + pt.z;
					b = qc.x;		
					c = qc.y;
					d = qc.z;
					a = qc.w;
					if (a>0)	{b=-b; c=-c; d=-d;}		// this has caused me lots of headache
					var l:Number = Math.sqrt(a*a+b*b+c*c+d*d);
					if (l>0) {b/=l; c/=l; d/=l; a/=l;}
				}// endif pidx>-1
				R.push(new VertexData(tx,ty,tz,b,c,d));
			}
			
			return R;
		}//endfunction
		
		/**
		* returns the current position of ith bone 
		*/
		public function bonePosn(i:uint) : Vector3D
		{
			var boneData:VertexData = currentPoseData[i];
			return new Vector3D(boneData.vx,boneData.vy,boneData.vz);
		}//endfunction
		
		/**
		* returns the transform at ith bone joint
		*/
		public function boneTransform(i:uint) : Matrix4x4
		{
			var boneData:VertexData = currentPoseData[i];
			var b:Number = boneData.nx;
			var c:Number = boneData.ny;
			var d:Number = boneData.nz;
			var a:Number = 1-b*b-c*c-d*d;
			if (a<0)	a=0;
			a = -Math.sqrt(a);
			var T:Matrix4x4 = Matrix4x4.quaternionToMatrix(a,b,c,d).translate(boneData.vx,boneData.vy,boneData.vz);
			return T;
		}//endfunction
		
		/**
		* returns the animation frame rate
		*/
		public function animationFrameRate(animId:String) : Number
		{
			if (Animations.indexOf(animId)!=-1)	// if animation with id exists
			{
				var frameRate:Number = Animations[Animations.indexOf(animId)+1];
				return frameRate;
			}
			else return 0;
		}//endfunction
		
		/**
		* returns the number of animation frames
		*/
		public function animationFrames(animId:String) : int
		{
			if (Animations.indexOf(animId)!=-1)	// if animation with id exists
			{
				var Frames:Array = Animations[Animations.indexOf(animId)+2];
				return Frames.length;
			}
			else return 0;
		}//endfunction
		
		/**
		* returns the animation duration in secs
		*/
		public function animationLength(animId:String) : Number
		{
			if (Animations.indexOf(animId)!=-1)	// if animation with id exists
			{
				var frameRate:Number = Animations[Animations.indexOf(animId)+1];
				var Frames:Array = Animations[Animations.indexOf(animId)+2];
				return Frames.length/frameRate;
			}
			else return 0;
		}//endfunction
		
		/**
		* returns the string ids of all existing animations
		*/
		public function getAnimationIds() : Array
		{
			var A:Array = [];
			for (var i:int=0; i<Animations.length; i+=3)
				A.push(Animations[i]);
			return A;
		}//endfunction
		
		/**
		* set skin mesh to display animation pose of given animId at given second, 
		* if 2nd animation is named, interpolate between the 2 
		*/
		public function setAnimation(animId:String,secs:Number,animId2:String=null,secs2:Number=0,inter:Number=0.5) : void
		{
			if (Animations.indexOf(animId)!=-1)	// if animation with id exists
			{
				var frameRate:Number = Animations[Animations.indexOf(animId)+1];
				var Frames:Array = Animations[Animations.indexOf(animId)+2];
				var frameIdx:Number = frameRate*secs;
				while (frameIdx<0) frameIdx += Frames.length;
				var idx1:int=int(frameIdx)%Frames.length;
				var idx2:int=(idx1+1)%Frames.length;
				var frameData:Vector.<VertexData> = interpolateFrames(Frames[idx1],Frames[idx2],frameIdx-int(frameIdx));
				
				// ----- if animation 2 is named, interpolate between animations 1 and 2
				if (animId2!=null && Animations.indexOf(animId2)!=-1)
				{
					frameRate = Animations[Animations.indexOf(animId2)+1];
					Frames = Animations[Animations.indexOf(animId2)+2];
					frameIdx = frameRate*secs2;
					while (frameIdx<0) frameIdx += Frames.length;
					idx1=int(frameIdx)%Frames.length;
					idx2=(idx1+1)%Frames.length;
					var frameData2:Vector.<VertexData> = interpolateFrames(Frames[idx1],Frames[idx2],frameIdx-int(frameIdx));
					frameData = interpolateFrames(frameData,frameData2,Math.min(1,Math.max(0,inter)));
				}
								
				currentPoseData = jointOrientationsToObjectSpace(frameData);
				if (GPUSkinning)
					GPUSkinningUpdateJoints(currentPoseData);	// send new joints orientations data to GPU
				else
					generateSkinPose(currentPoseData);
			}
		}//endfunction
		
		/**
		* set skin mesh to display animation pose of given animId at given animation frame, (requires less cpu than setAnimation)
		* if 2nd animation is named, interpolate between the 2
		*/
		private var interpData:Vector.<VertexData> = null;
		public function setAnimationFrame(animId:String,frame:uint,animId2:String=null,frame2:uint=0,inter:Number=0.5) : void
		{
			if (Animations.indexOf(animId)!=-1)	// if animation with id exists
			{
				var Frames:Array = Animations[Animations.indexOf(animId)+2];
				frame = frame%Frames.length;
				var frameData:Vector.<VertexData> = Frames[frame];
				
				// ----- if animation 2 is named, interpolate between animations 1 and 2
				if (animId2!=null && Animations.indexOf(animId2)!=-1 && inter>0)
				{
					Frames = Animations[Animations.indexOf(animId2)+2];
					frame2 = frame2%Frames.length;
					var frameData2:Vector.<VertexData> = Frames[frame2];
					frameData = interpolateFrames(frameData,frameData2,Math.min(1,Math.max(0,inter)),interpData);
					interpData = frameData;
				}
				
				frameData = jointMassSimulate(frameData);	// 
				
				currentPoseData = jointOrientationsToObjectSpace(frameData);
				if (GPUSkinning)
					GPUSkinningUpdateJoints(currentPoseData);	// send new joints orientations data to GPU
				else
					generateSkinPose(currentPoseData);
			}
		}//endfunction
		
		/**
		* derive an interpolated frame from given frames fD1,fD2 at 0<t<1
		* expects fD1,fD2: [{px,py,pz, nx,ny,nz},...] where (px,py,pz)=posn, (nx,ny,nz)=quat 
		* returns interpolated data: [{px,py,pz, nx,ny,nz},...] where (px,py,pz)=posn, (nx,ny,nz)=quat 
		* if R is given, overwrite results into R
		*/
		private function interpolateFrames(fD1:Vector.<VertexData>,fD2:Vector.<VertexData>,t:Number,R:Vector.<VertexData>=null) : Vector.<VertexData>
		{
			t = Math.max(0,Math.min(1,t));
			var i:int=0;
			var n:uint = Math.min(fD1.length,fD2.length);
			if (R==null)
			{
				R = new Vector.<VertexData>();
				for (i=0; i<n; i++)	R.push(new VertexData());
				
			}
			for (i=0; i<n; i++)
			{
				// ----- position parameters
				var a:VertexData = fD1[i];
				var b:VertexData = fD2[i];
								
				// ----- quarternion parameters
				var b1:Number = a.nx;
				var c1:Number = a.ny;
				var d1:Number = a.nz;
				var a1:Number = 1-b1*b1-c1*c1-d1*d1;
				if (a1<0) {a1=Math.sqrt(b1*b1+c1*c1+d1*d1); b1/=a1; c1/=a1; d1/=a1; a1=0;}	
				a1 = -Math.sqrt(a1);
				var b2:Number = b.nx;
				var c2:Number = b.ny;
				var d2:Number = b.nz;
				var a2:Number = 1-b2*b2-c2*c2-d2*d2;
				if (a2<0) {a2=Math.sqrt(b2*b2+c2*c2+d2*d2); b2/=a2; c2/=a2; d2/=a2; a2=0;}	
				a2 = -Math.sqrt(a2);
				
				// ----- if quaternion interpolation is going long way, invert q1
				var dp:Number = a1*a2+b1*b2+c1*c2+d1*d2;
				if (dp<0)	
				{
					a1*=-1;	b1*=-1;	c1*=-1;	d1*=-1;
					dp = a1*a2+b1*b2+c1*c2+d1*d2;
				}
				
				// ----- quarternions linear interpolation hack (not using slerp, faster!)
				var a3:Number = a1+t*(a2-a1);
				var b3:Number = b1+t*(b2-b1);
				var c3:Number = c1+t*(c2-c1);
				var d3:Number = d1+t*(d2-d1);
				var l3:Number = a3*a3+b3*b3+c3*c3+d3*d3;	// normalize quaternion results
				if (l3>0)	{l3=1/l3; a3*=l3; b3*=l3; c3*=l3; d3*=l3;}
				var vd:VertexData = R[i];
				vd.vx = a.vx+t*(b.vx-a.vx);			// position data
				vd.vy = a.vy+t*(b.vy-a.vy);
				vd.vz = a.vz+t*(b.vz-a.vz);
				vd.nx = b3;							// quaternion data
				vd.ny = c3;
				vd.nz = d3;
				
				/*
				// ----- doing the slerp 
				var ang:Number = Math.acos(Math.min(1,Math.max(-1,dp)));	// half angle
				if (ang!=0)		// prevent division by 0
				{
					var sinA:Number = Math.sin(ang);
					var f1_a:Number = Math.sin((1-t)*ang)/sinA;
					var fa:Number = Math.sin(t*ang)/sinA;
					var b3:Number = f1_a*b1+fa*b2;
					var c3:Number = f1_a*c1+fa*c2;
					var d3:Number = f1_a*d1+fa*d2;
					var vd:VertexData = R[i];
					vd.vx = a.vx+t*(b.vx-a.vx);			// position data
					vd.vy = a.vy+t*(b.vy-a.vy);
					vd.vz = a.vz+t*(b.vz-a.vz);
					vd.nx = b3;							// quaternion data
					vd.ny = c3;
					vd.nz = d3;
					
				}
				else
				{
					var vd:VertexData = R[i];
					vd.vx = a.vx+t*(b.vx-a.vx);			// position data
					vd.vy = a.vy+t*(b.vy-a.vy);
					vd.vz = a.vz+t*(b.vz-a.vz);
					vd.nx = b1;							// quaternion data
					vd.ny = c1;
					vd.nz = d1;
				}
				*/
			}
			
			return R;
		}//endfunction
		
		/**
		* attach mass to joint of given joint id at dist away from joint pivot
		*/
		private var JtM:Vector.<VertexData> = null;
		public function attachMassToJoint(jid:uint,accelF:Number=0.1,dampF:Number=0.9):void
		{
			var n:uint = currentPoseData.length;
			if (JtM==null)		// init joint mass array
			{
				JtM = new Vector.<VertexData>(n);
				for (var i:int=0; i<n; i++)
					JtM.push(null);
			}
			jid = jid%n;
			
			JtM[jid] = new VertexData(0,0,0,Number.NaN,Number.NaN,Number.NaN,0,accelF,dampF);	// vx,vy,vz as vel, nx,ny,nz as posn , v as accelF w as damping factor
		}//endfunction
		
		/**
		* change UV to projection UV
		*/
		public function projectUVFromView(subMesh:uint=0,M:Matrix4x4=null,debugDraw:BitmapData=null):void
		{
			// ----- recalculate UVs to be front projection
			var bpFrame:Vector.<VertexData> = new Vector.<VertexData>();
			for (var b:int=0; b<BindPoseData.length; b+=3)
				bpFrame.push(BindPoseData[b+2]);
			
			var JTs:Vector.<Matrix4x4> = getTransforms(bpFrame);	// get skeleton pose joint transforms
			if (M!=null)
			for (var m:uint=0; m<JTs.length; m++)	// for each transform
				JTs[m] = M.mult(JTs[m]);
			
			for (m=0; m<MeshesData.length; m+=3)	// for each mesh
			if (subMesh*3==m)
			{
				var mT:Vector.<uint> = MeshesData[m+0];
				var mV:Vector.<Number> = MeshesData[m+1];
				var mW:Vector.<VertexData> = MeshesData[m+2];
								
				// ----- create working data vector if not exist
				var UVs:Vector.<Point> = new Vector.<Point>();
				var minX:Number = Number.MAX_VALUE;
				var maxX:Number = Number.MIN_VALUE;
				var minY:Number = Number.MAX_VALUE;
				var maxY:Number = Number.MIN_VALUE;
								
				// ----- calculate vertices positions
				for (var v:uint=0; v<mV.length; v+=4)	// for each vertex
				{
					var widx:int = mV[v+2];			// mW index
					var widxend:int = widx+mV[v+3];	// mW end index exclusive
					var vx:Number = 0;				// vertex value to accumulate
					var vy:Number = 0;
					var vz:Number = 0;
					for (var w:uint=widx; w<widxend; w++)
					{
						var wD:VertexData = mW[w];	// weight data 
						var weight:Number = wD.w;	// weight value
						var wpx:Number = wD.vx;		// weight posn
						var wpy:Number = wD.vy;		// weight posn
						var wpz:Number = wD.vz;		// weight posn
						var jT:Matrix4x4 = JTs[wD.idx];	//joint transform
						
						vx+= weight*(jT.aa*wpx + jT.ab*wpy + jT.ac*wpz + jT.ad);
						vy+= weight*(jT.ba*wpx + jT.bb*wpy + jT.bc*wpz + jT.bd);
						vz+= weight*(jT.ca*wpx + jT.cb*wpy + jT.cc*wpz + jT.cd);
					}
					
					// ----- store UV vals
					UVs.push(new Point(vx,vy));
					if (minX>vx) minX=vx;
					if (maxX<vx) maxX=vx;
					if (minY>vy) minY=vy;
					if (maxY<vy) maxY=vy;
					
				}//endfor each vertex
				
				// ----- normalize UVs
				for (var u:int=UVs.length-1; u>-1; u--)
				{
					UVs[u].x=(UVs[u].x-minX)/(maxX-minX);
					UVs[u].y=(UVs[u].y-minY)/(maxY-minY);
					if (debugDraw!=null)
						debugDraw.fillRect(new Rectangle(debugDraw.width*UVs[u].x-1,debugDraw.height*UVs[u].y-1,3,3),0xFF336699);
				}
				
				// ----- rewrite UVs 
				for (v=0; v<mV.length; v+=4)	// for each vertex
				{
					var uv:Point = UVs.shift();
					mV[v+0] = uv.x;
					mV[v+1] = uv.y;
				}
				
				if (GPUSkinning)	GPUSkinningPrep();
			}//endfor each mesh
		}//endfunction
		
		/**
		* 
		*/
		public function offsetBones(boneIds:Vector.<int>,K:Vector.<Vector3D>):void
		{
			var n:uint = BindPoseData.length/3;
			for (var i:int=0; i<boneIds.length; i++)
			{
				var jid:uint = boneIds[i]%n;
				var pid:uint = jid;
				if (jid!=-1)	pid = BindPoseData[jid*3+1];
				
				// ----- shift joint positions in animation frames ------------
				for (var a:int=0; a<Animations.length; a+=3)
				{
					var Frames:Array = Animations[a+2];		// animation sequence
					for (var f:int=Frames.length-1; f>-1; f--)
					{
						var Frame:Vector.<VertexData> = Frames[f];	// animation frame
						var jtV:Vector3D = posnToJointSpace(K[i],pid,Frame,true);
						Frame[jid].vx+=jtV.x;
						Frame[jid].vy+=jtV.y;
						Frame[jid].vz+=jtV.z;
					}//endfor f
				}//endfor a
				
				// ----- shift joint positions in bind pose -------------------
				var bpFrame:Vector.<VertexData> = new Vector.<VertexData>();
				for (f=0; f<BindPoseData.length; f+=3)
					bpFrame.push(BindPoseData[f+2]);
				
				bpFrame[jid].vx+=K[i].x;
				bpFrame[jid].vy+=K[i].y;
				bpFrame[jid].vz+=K[i].z;
			}//endfor i
			
		}//endfunction
		
		/**
		* modifies mesh shape, move vertices in direction of vertices normals by k
		*/
		public function shrinkFattenBoneVertices(boneIds:Vector.<int>,K:Vector.<Number>):void
		{
			var i:int=0;
			var n:uint = BindPoseData.length/3;
			var nrm:Vector3D = null;
			if (n==0) return;
			
			// ----- determine joint transform and inverse --------------------
			var Ks:Vector.<Number> = new Vector.<Number>();
			for (i=0; i<n; i++)
			{
				if (boneIds.indexOf(i)!=-1)
					Ks.push(K[boneIds.indexOf(i)]);
				else
					Ks.push(0);
			}//endfor
			
			// ----- shift vertices matching boneId for each submesh ----------
			for (var m:int=MeshesData.length-3; m>=0; m-=3)
			{
				var mV:Vector.<Number> = MeshesData[m+1];
				var mW:Vector.<VertexData> = MeshesData[m+2];
				var nwn:int = mW.length;
				for (i=0; i<nwn; i++)		// for each weight
				{
					var w:VertexData = mW[i];
					if (w.w>0 && Ks[w.idx]!=0)
					{
						var f:Number = Ks[w.idx];
						w.vx+=f*w.nx;
						w.vy+=f*w.ny;
						w.vz+=f*w.nz;
					}//endif
				}//endfor j
			}//endfor
			
			if (GPUSkinning) GPUSkinningPrep();	// update GPU skinning data
		}//endfunction
		
		/**
		* modifies mesh shape, move vertices away from bone center by k
		*/
		public function scaleBoneVertices(boneIds:Vector.<int>,K:Vector.<Number>):void
		{
			var i:int=0;
			var n:uint = BindPoseData.length/3;
			var nrm:Vector3D = null;
			if (n==0) return;
			
			// ----- determine joint transform and inverse --------------------
			var Ks:Vector.<Number> = new Vector.<Number>();
			for (i=0; i<n; i++)
			{
				if (boneIds.indexOf(i)!=-1)
					Ks.push(K[boneIds.indexOf(i)]);
				else
					Ks.push(0);
			}//endfor
			
			// ----- shift vertices matching boneId for each submesh ----------
			for (var m:int=MeshesData.length-3; m>=0; m-=3)
			{
				var mV:Vector.<Number> = MeshesData[m+1];
				var mW:Vector.<VertexData> = MeshesData[m+2];
				var nwn:int = mW.length;
				for (i=0; i<nwn; i++)		// for each weight
				{
					var w:VertexData = mW[i];
					if (w.w>0 && Ks[w.idx]!=0)
					{
						var f:Number = Math.sqrt(w.vx*w.vx+w.vy*w.vy+w.vz*w.vz);
						if (f>0)
						{
							f = w.w*Ks[w.idx]/f;
							w.vx+=f*w.vx;
							w.vy+=f*w.vy;
							w.vz+=f*w.vz;
						}
					}//endif
				}//endfor j
			}//endfor
			
			if (GPUSkinning) GPUSkinningPrep();	// update GPU skinning data
		}//endfunction
		
		/**
		* given bones quaternion and translation frame data (not conv to obj space), tweak rotations to simulate mass effect
		*/
		//public var massTrace:Mesh = null;
		private function jointMassSimulate(frameData:Vector.<VertexData>) : Vector.<VertexData>
		{
			if (JtM==null) return frameData;
			
			if (frameData==null)	frameData = currentPoseData;
			frameData = frameData.slice();
									
			//if (massTrace==null)	massTrace = new Mesh();
						
			var b:Number = 0;
			var c:Number = 0;
			var d:Number = 0;
			var a:Number = 0;
			
			//var mkrCnt:int=0;
			for (var i:int=0; i<JtM.length; i++)
				if (JtM[i]!=null)
				{
					var m:VertexData = JtM[i];			// joint mass
					var jt:VertexData = frameData[i];	// joint quat and posn
					b = jt.nx;
					c = jt.ny;
					d = jt.nz;
					a = 1-b*b-c*c-d*d;
					if (a<0) {a=Math.sqrt(b*b+c*c+d*d); b/=a; c/=a; d/=a; a=0;}	
					a =-Math.sqrt(a);
					var pt:Vector3D = new Vector3D(0,0.05,0);
					pt = posnToObjectSpace(pt,i,frameData);	// targ pt in object space!
					
					if (isNaN(m.nx) || isNaN(m.ny) || isNaN(m.nz))
					{
						m.nx=pt.x;			// in object space!
						m.ny=pt.y;
						m.nz=pt.z;
					}
					else
					{
						var dx:Number = pt.x-m.nx;	// in object space!
						var dy:Number = pt.y-m.ny;
						var dz:Number = pt.z-m.nz;
						m.vx+=dx*m.v;		// verlet add velocity*accelF
						m.vy+=dy*m.v;
						m.vz+=dz*m.v;
						m.vx*=m.w;			// apply vel dampening
						m.vy*=m.w;
						m.vz*=m.w;
						m.nx+=m.vx;			// inc posn with vel
						m.ny+=m.vy;
						m.nz+=m.vz;
						
						var wPt:Vector3D = new Vector3D(pt.x-dx,pt.y-dy,pt.z-dz);	// weight point in object space
						pt = quatMult(b,c,d,a, 0,0.05,0,0);	
						pt = quatMult(pt.x,pt.y,pt.z,pt.w, -b,-c,-d,a);				
						pt.x += jt.vx; pt.y+=jt.vy; pt.z+=jt.vz;					// targ pt in parent space of joint
						wPt = posnToJointSpace(wPt,BindPoseData[i*3+1],frameData);	// weight pt in parent space of joint
						dx = wPt.x-jt.vx;
						dy = wPt.y-jt.vy;
						dz = wPt.z-jt.vz;
						var dl:Number = Math.sqrt(dx*dx+dy*dy+dz*dz);
						wPt = new Vector3D(jt.vx+dx/dl*0.05,jt.vy+dy/dl*0.05,jt.vz+dz/dl*0.05); 
						pt.normalize();
						wPt.normalize();
						var ang:Number = Math.acos(Math.max(-1,Math.min(1,wPt.x*pt.x+wPt.y*pt.y+wPt.z*pt.z)));
						if (ang*ang>0.000000001)
						{
							var axis:Vector3D = pt.crossProduct(wPt);
							axis.normalize();
							var cosA_2:Number = Math.cos(ang/2);
							var sinA_2:Number = Math.sin(ang/2);
							pt = quatMult(axis.x*sinA_2,axis.y*sinA_2,axis.z*sinA_2,cosA_2, b,c,d,a);	// tweaked quaternion
							b = pt.x;
							c = pt.y;
							d = pt.z;
							a = pt.w;
							if (a>0)	{b=-b; c=-c; d=-d;}		// this has caused me lots of headache
							var l:Number = Math.sqrt(a*a+b*b+c*c+d*d);
							if (l>0) {b/=l; c/=l; d/=l; a/=l;}
							frameData[i] = new VertexData(jt.vx,jt.vy,jt.vz,b,c,d,jt.u,jt.v,jt.w,jt.idx);
						}
					}
					
					// ----- place marker at correct position
					/*
					mkrCnt++;
					if (massTrace.childMeshes.length<mkrCnt)
						massTrace.addChild(Mesh.createSphere(0.005));
					var mkr:Mesh = massTrace.childMeshes[mkrCnt-1];
					mkr.transform = new Matrix4x4().translate(m.nx,m.ny,m.nz);
					*/
				}//endif
				
			return frameData;
		}//endfunction
		
		/**
		* converts position in root space to position in joint space
		*/
		private function posnToJointSpace(pt:Vector3D,jid:uint,frameData:Vector.<VertexData>,dirOnly:Boolean=false) : Vector3D
		{
			jid = jid%frameData.length;
			
			// ----- find path from parent to target child bone
			var P:Vector.<int> = new Vector.<int>();
			var pid:int=jid;
			P.push(pid);
			while (pid!=-1)
			{
				pid = BindPoseData[pid*3+1];
				P.push(pid);
			}	// p contains child to parent root
			
			P.pop();	// remove the -1 at the end
			// ----- convert point to joint space
			while (P.length>0)
			{
				var jt:VertexData = frameData[P.pop()];
				var b:Number = jt.nx;
				var c:Number = jt.ny;
				var d:Number = jt.nz;
				var a:Number = 1-b*b-c*c-d*d;
				if (a<0) {a=Math.sqrt(b*b+c*c+d*d); b/=a; c/=a; d/=a; a=0;}	
				a =-Math.sqrt(a);
				if (dirOnly)	pt = quatMult(b,c,d,-a, pt.x,pt.y,pt.z,0);
				else			pt = quatMult(b,c,d,-a, pt.x-jt.vx,pt.y-jt.vy,pt.z-jt.vz,0);
				pt = quatMult(pt.x,pt.y,pt.z,pt.w, -b,-c,-d,-a);	// reverse rotated target point
			}
			return pt;
		}//endfunction
		
		/**
		* converts position in joint space to position in root space
		*/
		private function posnToObjectSpace(pt:Vector3D,jid:uint,frameData:Vector.<VertexData>):Vector3D
		{
			jid = jid%frameData.length;
			var pid:int=jid;
			while (pid!=-1)
			{
				var jt:VertexData = frameData[pid];
				var b:Number = jt.nx;
				var c:Number = jt.ny;
				var d:Number = jt.nz;
				var a:Number = 1-b*b-c*c-d*d;
				if (a<0) {a=Math.sqrt(b*b+c*c+d*d); b/=a; c/=a; d/=a; a=0;}	
				a =-Math.sqrt(a);
				pt = quatMult(b,c,d,a, pt.x,pt.y,pt.z,0);	
				pt = quatMult(pt.x,pt.y,pt.z,pt.w, -b,-c,-d,a);	// rotated target point
				pt = new Vector3D(pt.x+jt.vx , pt.y+jt.vy , pt.z+jt.vz);
				pid = BindPoseData[pid*3+1];	// [jointName,parentIdx,jointData, ...]
			}
			return pt;
		}//endfunction
		
		/**
		* Clears off any current verlet rag doll working state
		*/
		public function resetRagDoll() : void	{VPJPs=null;}//endfunction
		
		/**
		* use verlet simulation to animate character as ragdoll 
		*	Verlet Physics : x_new = x + (x-x_old) + a*t*t
		*	Verlet Physics time corrected : x_new = x + (x-x_old)*(t/t_old) + a*t*t
		* reference BindPose=[jointName,parentIdx,jointData, ...] where jointData: vx,vy,vz=position nx,ny,nz=quaternion 
		* given 
		*	fD=[{vx,vy,vz, nx,ny,nz},...] where (vx,vy,vz)=posn, (nx,ny,nz)=quat  in joints space
		*	M:Mesh supplying the collision geometry for ragdoll to fall on
		*	g:Vector3D the acceleration acting on the joint points
		*/
		public function simulateRagDoll(g:Vector3D,M:Mesh) : void
		{
			var T:Matrix4x4 = skin.transform;		// skin transform to external space
			if (T==null)	T = new Matrix4x4();
			var invT:Matrix4x4 = T.inverse();		// inverse to skin transform
						
			var i:int=0;
			var dx:Number=invT.aa*g.x + invT.ab*g.y + invT.ac*g.z;
			var dy:Number=invT.ba*g.x + invT.bb*g.y + invT.bc*g.z;
			var dz:Number=invT.ca*g.x + invT.cb*g.y + invT.cc*g.z;
			g.x=dx;	g.y=dy;	g.z=dz;	// transform g to object space
			var pidx:int=0;
			var jt:VertexData;		// joint data
			var pjt:VertexData;		// parent joint data
			var opt:Vector3D;		// prev joint posn
			
			// ----- convert joint orientations to object space ---------------
			var fD:Vector.<VertexData> = currentPoseData;
			
			// ----- calculate length restrictions between joints -------------
			if (VPJPs==null)	// if previous joint positions and length data is non existant
			{
				VPJPs = new Vector.<Vector3D>();	// prev positions of each joint
				jt = BindPoseData[2];						// root joint data
				VPJPs.push(new Vector3D(jt.vx,jt.vy,jt.vz));// root joint prev position
				for (i=1; i<fD.length; i++)
				{
					jt = BindPoseData[i*3+2];				// joint data
					pidx = BindPoseData[i*3+1];				// parent joint idx
					pjt = BindPoseData[pidx*3+2];			// parent joint data
					dx = jt.vx-pjt.vx;
					dy = jt.vy-pjt.vy;
					dz = jt.vz-pjt.vz;
					// record down current position and length to parent joint
					VPJPs.push(new Vector3D(fD[i].vx,fD[i].vy,fD[i].vz,Math.sqrt(dx*dx+dy*dy+dz*dz)));
				}//endfor
			}
			
			// ----- move joint points by velocity and g ----------------------
			for (i=0; i<fD.length; i++)
			{
				jt = fD[i];		// joint data in frame data
				opt = VPJPs[i];	// prev joint point
												
				// ----- move current position 
				dx = jt.vx-opt.x+g.x;	// next dist x travelled
				dy = jt.vy-opt.y+g.y;	// next dist y travelled
				dz = jt.vz-opt.z+g.z;	// next dist z travelled
				// ----- record previous position
				opt.x = jt.vx;
				opt.y = jt.vy;
				opt.z = jt.vz;
				jt.vx+= dx;
				jt.vy+= dy;
				jt.vz+= dz;
			}//endfor
			
			// ----- shift joints to maintain orientation wrt to parent -------
			for (i=0; i<fD.length; i++)
			{
			}//endfor
			
			// ----- apply length restrictions to joints ----------------------
			for (i=1; i<fD.length; i++)
			{
				jt = fD[i];
				pidx = BindPoseData[i*3+1];			// parent joint idx
				pjt = fD[pidx];
				var l:Number = VPJPs[i].w;			// specified length
				dx = jt.vx-pjt.vx;
				dy = jt.vy-pjt.vy;
				dz = jt.vz-pjt.vz;
				var dl:Number = Math.sqrt(dx*dx+dy*dy+dz*dz); // current length
				if (dl>0) {dx/=dl;	dy/=dl;	dz/=dl;}// normalize direction
				var f:Number = (dl-l)/2;			// half distance
				jt.vx-=f*dx;						// shift back joint by f
				jt.vy-=f*dy;
				jt.vz-=f*dz;
				pjt.vx+=f*dx;						// shift forward parent by f
				pjt.vy+=f*dy;
				pjt.vz+=f*dz;
			}//endfor
						
			// ----- joint collision check ------------------------------------
			for (i=1; i<fD.length; i++)	// dont test root joint
			{
				jt = fD[i];			// ending position
				opt = VPJPs[i];		// starting position
				dx = jt.vx-opt.x;	// final dist x to travel
				dy = jt.vy-opt.y;	// final dist y to travel
				dz = jt.vz-opt.z;	// final dist z to travel
				if (dx*dx+dy*dy+dz*dz>0)	// if moving
				{
					var epx:Number= T.aa*opt.x + T.ab*opt.y + T.ac*opt.z + T.ad;	// transform to world coords
					var epy:Number= T.ba*opt.x + T.bb*opt.y + T.bc*opt.z + T.bd; 
					var epz:Number= T.ca*opt.x + T.cb*opt.y + T.cc*opt.z + T.cd; 
					var evx:Number= T.aa*dx + T.ab*dy + T.ac*dz;					// transform to world vector
					var evy:Number= T.ba*dx + T.bb*dy + T.bc*dz;
					var evz:Number= T.ca*dx + T.cb*dy + T.cc*dz;
					var evl:Number = Math.sqrt(evx*evx+evy*evy+evz*evz);
					//var ux:Number=evx/evl;
					//var uy:Number=evy/evl;
					//var uz:Number=evz/evl;
					//var hit:VertexData = M.lineHitsMesh(epx-ux*0.01,epy-uy*0.01,epz-uz*0.01,
					//									evx+ux*0.01,evy+uy*0.01,evz+uz*0.01);
					var hit:VertexData = M.lineHitsMesh(epx,epy,epz,evx,evy,evz);
					if (hit!=null)
					{
						// ----- calculate ratio of dist to hit pt
						var r:Number = Math.sqrt((hit.vx-epx)*(hit.vx-epx)+(hit.vy-epy)*(hit.vy-epy)+(hit.vz-epz)*(hit.vz-epz))/evl;
						//debugTf.appendText("hit:"+hit+"  r:"+r);
						jt.vx = opt.x+dx*r;
						jt.vy = opt.y+dy*r;
						jt.vz = opt.z+dz*r;
						
						// ----- calculate hit normal in obj space
						var ux:Number = (invT.aa*hit.nx + invT.ab*hit.ny + invT.ac*hit.nz)*0.001;	
						var uy:Number = (invT.ba*hit.nx + invT.bb*hit.ny + invT.bc*hit.nz)*0.001; 
						var uz:Number = (invT.ca*hit.nx + invT.cb*hit.ny + invT.cc*hit.nz)*0.001; 
						//debugTf.appendText("  hit normal=("+int(ux*100)/100+","+int(uy*100)/100+","+int(uz*100)/100+")\n");
						
						// ----- apply push from this particular joint to connecting joints 
						fD[i].vx+=ux;	// maintain hit surface separation
						fD[i].vy+=uy;
						fD[i].vz+=uz;
					}
				}//endif
			}	
			
			// ----- recalculate joint orientations ---------------------------
			//???
			
			// ----- update skin according to joint posns ---------------------
			if (GPUSkinning)
				GPUSkinningUpdateJoints(currentPoseData);	// send new joints orientations data to GPU
			else
				generateSkinPose(currentPoseData);
		}//endfunction
						
		/**
		* load and update the texture of current skin
		*/
		public function loadTexture(url:String,callBack:Function=null) : void
		{
			var ldr:Loader = new Loader();
			function loadCompleteHandler(e:Event):void
			{
				trace("loaded texture:"+ldr.content);	
				var bmp:Bitmap = (Bitmap)(ldr.content); 
				skin.setTexture(bmp.bitmapData,true);
				if (callBack!=null) callBack(bmp.bitmapData); 
			}
				try {ldr.load(new URLRequest(url));}	catch (error:SecurityError)	
			{trace("texture load failed: SecurityError has occurred.\n");}
			ldr.addEventListener(IOErrorEvent.IO_ERROR, function(e:Event):void {trace("texture load IO Error occurred! e:"+e+"\n");});
			ldr.contentLoaderInfo.addEventListener(Event.COMPLETE, loadCompleteHandler);
		}//endfunction
				
		/**
		* loads and adds an animation sequence to this 
		*/
		public function loadAnim(animId:String,url:String,fn:Function=null) : void
		{
			// ----- loads the obj file first ------------------------------------------
			var ldr:URLLoader = new URLLoader();
			try {ldr.load(new URLRequest(url));}	catch (error:SecurityError)	
			{}
			ldr.addEventListener(IOErrorEvent.IO_ERROR, function(e:Event):void {});
			ldr.addEventListener(Event.COMPLETE, function (e:Event):void
			{
				parseAnimation(ldr.data,animId);
				// ----- callback Fn --------------------------------
				if (fn!=null)	fn();
			});
		}//endfunction
		
		/**
		* parses animation sequence and binds animId identifier to it 
		*/
		public function parseAnimation(s:String,animId:String) : void
		{
			// ----- get frameRate data
			var tmp:String = s.substr(s.indexOf("frameRate")+9);
			var frameRate:int = Number(tmp.substr(0,tmp.indexOf("\n")));
			
			s = s.substr(s.indexOf("hierarchy"));	// prevent frame 0 parsing error
			
			var o:Object =removeDataSeg(s,"hierarchy");
			s = o.s;
			var H:Array = parseNples(o.seg,4);		// [boneName,parentIdx,numComp,frameIdx,...] hierachy data
			
			o =removeDataSeg(s,"bounds");
			s = o.s;
			var Bnds:Array = parseNples(o.seg,6);	// [minX,minY,minZ,maxX,maxY,maxZ,...] bounds data
			
			o =removeDataSeg(s,"baseframe");
			s = o.s;
			var BF:Array = parseNples(o.seg,6);		// [px,py,pz,xOrient,yOrient,zOrient,...] base frame data
			
			// ----- parse frames data --------------------------
			var Frames:Array = [];
			while (s.indexOf("frame")!=-1)
			{
				o =removeDataSeg(s,"frame");
				s = o.s;
				Frames.push(parseFrame(o.seg,H,BF));
			}
			
			Animations.push(animId,frameRate,Frames);
		}//endfunction
		
		/**
		* Loads MD5Mesh file, exec fn after loading complete and passes back a MD5Animae
		*/
		public static function loadModel(url:String,fn:Function=null) : void
		{
			// ----- loads the obj file first ------------------------------------------
			var ldr:URLLoader = new URLLoader();
			try {ldr.load(new URLRequest(url));}	catch (error:SecurityError)	
			{}
			ldr.addEventListener(IOErrorEvent.IO_ERROR, function(e:Event):void {});
			ldr.addEventListener(Event.COMPLETE, function (e:Event):void
			{
				if (fn!=null)	fn(parseMesh(ldr.data));
			});
		}//endfunction
				
		/**
		* parses data string and returns MD5Animae with mesh and skeleton data 
		*/
		public static function parseMesh(s:String) : MD5Animae
		{
			var tmp:String = "";
			
			// ----- get numJoints data
			tmp = s.substr(s.indexOf("numJoints")+9);
			var numJoints:int = Number(tmp.substr(0,tmp.indexOf("\n")));
			
			// ----- get numMeshes data
			tmp = s.substr(s.indexOf("numMeshes")+9);
			var numMeshes:int = Number(tmp.substr(0,tmp.indexOf("\n")));
			
			// ----- get Joints data string segment
			var o:Object = removeDataSeg(s,"joints");
			var BindPoseData:Array = parseBindPose(o.seg);
			s = o.s;
			
			//if (debugTf!=null) debugTf.appendText("o.s="+o.s);
			
			var MeshesData:Array = [];
			while (s.indexOf("mesh")!=-1)
			{
				//if (debugTf!=null) debugTf.appendText("s="+s+"\n");
				o = removeDataSeg(s,"mesh");
				s = o.s;
				o = parseWeights(o.seg);		// parse MD5 mesh data
				if (o.mT.length>0 && o.mV.length>0 && o.mW.length>0)	
					MeshesData.push(o.mT,o.mV,o.mW);
			}//endwhile
			
			return new MD5Animae(BindPoseData,MeshesData);
		}//endfunction
				
		/**
		* converts the quaternion based joint orientation and translation to matrices and return in joints order
		*/
		private static function getTransforms(frameData:Vector.<VertexData>) : Vector.<Matrix4x4>
		{
			var JTs:Vector.<Matrix4x4> = new Vector.<Matrix4x4>();
			var n:uint = frameData.length;
			// ----- pregenrate joint transform matrices ----------------------
			for (var j:int=0; j<n; j++)
			{
				var jt:VertexData = frameData[j];
				var b:Number = jt.nx;
				var c:Number = jt.ny;
				var d:Number = jt.nz;
				var a:Number = 1-b*b-c*c-d*d;
				if (a<0)	a=0;
				a = -Math.sqrt(a);
				var jT:Matrix4x4 = Matrix4x4.quaternionToMatrix(a,b,c,d).translate(jt.vx,jt.vy,jt.vz);
				JTs.push(jT);
			}
			return JTs;
		}//endfunction
		
		/**
		* convenience function for quaternion multiplication
		*/
		private static function quatMult(	qax:Number,qay:Number,qaz:Number,qaw:Number,
											qbx:Number,qby:Number,qbz:Number,qbw:Number) : Vector3D
		{
			var qc:Vector3D = new Vector3D(	qax*qbw + qaw*qbx + qay*qbz - qaz*qby,	// x
											qay*qbw + qaw*qby + qaz*qbx - qax*qbz,	// y
											qaz*qbw + qaw*qbz + qax*qby - qay*qbx,	// z
											qaw*qbw - qax*qbx - qay*qby - qaz*qbz);	// w real
			
			return qc;
		}//endfunction
				
		/**
		* parse the animation frame, combining baseframe data with this frame data
		* expects H:	[boneName,parentIdx,numComp,frameIdx,...]	// Hierarchy data
		* expects BF:	[px,py,pz,xOrient,yOrient,zOrient,...]		// base frame data
		* produce complete frame pose data. returns [{px,py,pz, nx,ny,nz},...] (px,py,pz):posn, (nx,ny,nz):quat 
		*/
		private static function parseFrame(s:String,H:Array,BF:Array) : Vector.<VertexData>
		{
			var i:int=0;
			var dat:Array = null;
			var R:Vector.<VertexData> = new Vector.<VertexData>();
			var S:Array = prepData(s);
			
			var F:Array = [];		// F to contain frame data
			for (i=0; i<S.length; i++)
			{
				dat = S[i].split(" ");
				while (dat.length>0)
				{
					var d:String = dat.shift();
					if (!isNaN(Number(d)))	F.push(Number(d));
				}
			}//endfor
			
			var n:int = H.length/4;
			for (i=0; i<n; i++)
			{
				var bits:uint = uint(H[i*4+2]);		// selection bits
				dat = [BF[i*6+0],BF[i*6+1],BF[i*6+2],BF[i*6+3],BF[i*6+4],BF[i*6+5]];
				var idx:int = int(H[i*4+3]);
				for (var b:uint=0; b<6; b++)
					if ((bits&(1<<b))!=0)
						dat[b] = F[idx++];
				
				R.push(new VertexData(dat[0],dat[1],dat[2],dat[3],dat[4],dat[5]));	// push combined result
			}//endfor
			
			return R;
		}//endfunction
		
		/**
		* given string segment containing joints data of the MD5mesh parse and 
		* returns Array [jointName,parentIdx,jointData, ...] where jointData: vx,vy,vz=position nx,ny,nz=quaternion 
		*/
		private static function parseBindPose(s:String) : Array
		{
			var i:int=0;
			var R:Array = [];
			var dat:Array = [];
			
			var S:Array = prepData(s);
			var n:int=S.length;
			for (i=0; i<n; i++)
			{
				dat = S[i].split(" ");
				if (dat.length>=8)
				{
					dat.splice(8,dat.length-8);
					var b:Number = Number(dat[5]);	// quaternion vector component (b,c,d)
					var c:Number = Number(dat[6]);
					var d:Number = Number(dat[7]);
					var a:Number =-Math.sqrt(1-b*b-c*c-d*d);
					// ----- derive joint orientation matrix
					var jdata:VertexData = new VertexData(	Number(dat[2]),Number(dat[3]),Number(dat[4]),	// joint position tx,ty,tz
															Number(dat[5]),Number(dat[6]),Number(dat[7]));	// quaternion data qb,qc,qd
					R.push(dat[0],Number(dat[1]),jdata);
				}
			}//endfor
				
			return R;
		}//endfunction
				
		/**
		* parse the Md5Mesh geometry data
		* returns Object {mV:Array mT,Array, mW:Array}
		* mV:Vector.<Number> = [texU,texV,weightIndex,weightElem,...]
		* mT:Vector.<uint> = [vertIndex1,vertIndex2,vertIndex3,...]
		* mW:Vector.<VertexData> = [{vx=xPos,vy=yPos,vz=zPos,w=weightValue,idx=jointIndex},...]
		*/
		private static function parseWeights(s:String) : Object
		{
			var mV:Vector.<Number> = new Vector.<Number>();	// [texU,texV,weightIndex,weightElem,...]
			var mT:Vector.<uint> = new Vector.<uint>();		// [vertIndex1,vertIndex2,vertIndex3,...]
			var mW:Vector.<VertexData> = new Vector.<VertexData>();	// [{vx=xPos,vy=yPos,vz=zPos,w=weightValue,idx=jointIndex},...]
			
			var S:Array = prepData(s);
			var n:int=S.length;
			for (var i:uint=0; i<n; i++)
			{
				s = S[i];
				var A:Array = s.split(" ");
				var idx:int = Number(A[1]);
				if (s.substr(0,4)=="vert")
				{
					mV[idx*4+0] = Number(A[2]);	// texU
					mV[idx*4+1] = Number(A[3]);	// texV
					mV[idx*4+2] = Number(A[4]);	// weightIndex
					mV[idx*4+3] = Number(A[5]);	// weightElem
				}
				if (s.substr(0,3)=="tri")
				{
					mT[idx*3+0] = uint(Number(A[2]));	// vertIndex 1
					mT[idx*3+1] = uint(Number(A[4]));	// vertIndex 2
					mT[idx*3+2] = uint(Number(A[3]));	// vertIndex 3
				}
				if (s.substr(0,6)=="weight")
				{
					mW[idx] = new VertexData(Number(A[4]),Number(A[5]),Number(A[6]),0,0,0,0,0,Number(A[3]),Number(A[2]));
				}
			}//endfor
			
			var o:Object = new Object();
			o.mV = mV;
			o.mT = mT;
			o.mW = mW;
			
			return o;
		}//endfunction
		
		/**
		* convenience function given string of space delimited lines of data
		* returns flattened array containing data [d1,d2,...,dn,d1,d2,...,dn,...]
		*/
		private static function parseNples(s:String,n:uint=1) : Array
		{
			var R:Array = [];
			var S:Array = prepData(s);
			var l:int=S.length;
			for (var i:uint=0; i<l; i++)
			{
				var dat:Array = S[i].split(" ");
				if (dat.length>=n)
				{
					for (var j:uint=0; j<n; j++)
						if (isNaN(Number(dat[j])))
							R.push(dat[j]);
						else
							R.push(Number(dat[j]));
				}
			}
			return R;
		}//endfunction
		
		/**
		* convenience function to remove unecessary characters in a line of data
		*/
		private static function prepData(s:String) : Array
		{
			var S:Array = s.split("\n");
			var n:int=S.length;
			for (var i:int=n-1; i>=0; i--)
			{
				s = S[i];
				s = s.split("\t").join(" ").split("(").join("").split(")").join("").split("\"").join("").split("  ").join(" ").split("  ").join(" ").split("  ").join(" ").split("  ").join(" ");
				while (s.charAt(0)==" ") s=s.substr(1);
				if (s=="")
					S.splice(i,1)
				else
					S[i] = s;
			}
			return S;
		}//endfunction
		
		/**
		* convenience function to remove data segment with startTag
		*/
		private static function removeDataSeg(s:String,startTag:String) : Object
		{
			var seg:String = "";
		
			if (s.indexOf(startTag)!=-1)
			{
				seg = s.substr(s.indexOf(startTag));
				seg = seg.substr(0,seg.indexOf("}")+1);
				s = s.substr(0,s.indexOf(startTag)) + s.substr(s.indexOf(startTag)+seg.length);
				seg = seg.substr(seg.indexOf("\n"));
			}
			
			var o:Object = new Object();
			o.s = s;
			o.seg = seg;
			return o;
		}//endfunction
				
	}//endclass
}//endfunction
