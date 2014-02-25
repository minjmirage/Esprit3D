package core3D
{
	import flash.display.BitmapData;
	import flash.display.MovieClip;
	import flash.geom.Matrix;
	import flash.geom.Point;
	import flash.geom.Rectangle;
	import flash.geom.Vector3D;
	
	/**
	* Author: Lin Minjiang	2012/07/10	updated
	* Creates an emitter to emit lightning streamers of textured sequence specified by given movieClip.
	* Supports 120-2 points length of camera facing streamer on a single mesh
	*/
	public class StreamersEmitter
	{
		public var skin:Mesh;
		public var PData:Vector.<VertexData>;	// position, scaling and  of each particle
		
		public var spriteSheet:BitmapData;		// the spritesheet containing movieclip sequence
		public var nsp:uint = 1;				// number of sprites in a row in spritesheet
		public var totalFrames:uint=0;			// total frames of the movieclip
		public var lifeTime:uint=0;				// particle time to live after spawn
		
		public var wind:Vector3D;				// wind affecting the particles
		public var slowdown:Number=0.95;		// slowdown factor
		
		public var numLivePoints:uint=0;
		
		private static var noise:BitmapData;
		private static var noiseIdx:uint=0;
		
		/**
		* creates a 120 batch rendered animated bitmap particles at given positions
		*/
		public function StreamersEmitter(sheet:BitmapData,frames:uint,sc:Number=1,blend:String="add") : void
		{
			var i:int=0;
			
			wind = new Vector3D(0,0.0001,0);		// default wind
								
			// ----- generate spriteSheet ---------------------------
			spriteSheet = sheet;
			nsp = Math.ceil(Math.sqrt(frames));	// number of sprites in a row
			totalFrames = frames;
			lifeTime = totalFrames;
			
			// ----- default joint positions ------------------------
			PData = new Vector.<VertexData>();
			for (i=0; i<120; i++)
				PData.push(new VertexData(0,0,0, 0,0,0, 0,0,0, totalFrames));
						
			var sw:int = sheet.width/nsp;		// width of single sprite in sheet
			var sh:int = sheet.height/nsp;		// height of single sprite in sheet
						
			// ----- create interlinked streamer geometry -----------
			var idxOff:int = 7;			// vertex constants register offset
			var V:Vector.<Number> = new Vector.<Number>();	// vertices data
			var I:Vector.<uint> = new Vector.<uint>();		// indices data
			var w2:Number = sw/250*sc;
			var h2:Number = sh/250*sc;
			var f:Number = 1/nsp;
			for (i=0; i<PData.length; i++)
			{	// compromise, overlap render planes to prevent thin lines
				V.push(-w2,0,0, 0,0, idxOff+i);	// x,y,z, u,v, idx left
				V.push( w2,0,0, f,0, idxOff+i);	// x,y,z, u,v, idx right
				V.push(0,-h2,0, 0,0, idxOff+i);	// x,y,z, u,v, idx top
				V.push(0, h2,0, f,0, idxOff+i);	// x,y,z, u,v, idx bottom
				
				// links from this joint to next joint
				I.push(i*4+0,i*4+1,(i+1)*4+1);		// tri down A
				I.push(i*4+0,(i+1)*4+1,(i+1)*4+0);	// tri down B
				I.push((i+1)*4+0,(i+1)*4+1,i*4+1);	// tri up A
				I.push((i+1)*4+0,i*4+1,i*4+0);		// tri up B
				
				I.push(i*4+3,i*4+2,(i+1)*4+2);		// tri right A
				I.push(i*4+3,(i+1)*4+2,(i+1)*4+3);	// tri right B
				I.push((i+1)*4+3,(i+1)*4+2,i*4+2);	// tri left A
				I.push((i+1)*4+3,i*4+2,i*4+3);		// tri left B
			}
			for (i=8*3-1; i>=0; i--)	I.pop();	// remove tail excess
			
			skin = new Mesh();
			skin.castsShadow=false;
			skin.enableLighting(false);
			skin.setAmbient(1,1,1,0);
			skin.setParticles(V,I);
			skin.setTexture(spriteSheet);
			skin.setBlendMode(blend);
			
			if (noise==null)
			{
				noise = new BitmapData(100,100,false,0x000000);
				noise.perlinNoise(8, 8, 2, 0, true, true, 7, false, [new Point(0,0),new Point(0,0)]);
			}
		}//endfunction
		
		/**
		* connect a streamer from (px,py,pz) to (qx,qy,qz)
		*/
		public function fromTo(px:Number=0,py:Number=0,pz:Number=0,qx:Number=0,qy:Number=0,qz:Number=0,sc1:Number=1,sc2:Number=0.2,n:uint=20,dev:Number=0.02,initDev:Number=0.1) : void
		{
			if (n<2)	return;
			
			// ----- find unit directional vector
			var vx:Number = qx-px;
			var vy:Number = qy-py;
			var vz:Number = qz-pz;
			var vl:Number = Math.sqrt(vx*vx+vy*vy+vz*vz);
			if (vl<=0.0001) return;
			var _vl:Number = 1/vl;
			vx*=_vl; vy*=_vl; vz*=_vl;
			
			// ----- set scaling limit
			if (sc1>0.9999)	sc1=0.9999;		if (sc1<0) sc1=0;
			if (sc2>0.9999)	sc2=0.9999;		if (sc2<0) sc2=0;
						
			// ----- begin constrict
			var p:VertexData = PData.pop();
			if (p.idx>=lifeTime)	numLivePoints++;		// if was dead point
			p.nx = px;
			p.ny = py;
			p.nz = pz;
			p.vx = 0;
			p.vy = 0;
			p.vz = 0;
			p.w = 0;		// particle scale
			p.idx = 0;		// frame index
			PData.unshift(p);
			
			// ----- middle ribbon points						
			for (var i:int=0; i<n; i++)
			{
				p = PData.pop();
				if (p.idx>=lifeTime)	numLivePoints++;		// if was dead point
				
				var f:Number = i/(n-1);
				var sc:Number  = sc1*(1-f) + sc2*f;				// interpolate joint scale
				var tx:Number = px*(1-f) + qx*f;				// interpolate joint position
				var ty:Number = py*(1-f) + qy*f;
				var tz:Number = pz*(1-f) + qz*f;
				var c:uint = noise.getPixel(noiseIdx%100,int(noiseIdx/100));
				noiseIdx = (noiseIdx+1)%10000;
				var rx:Number = ((c & 0xFF)-127)/127;
				var ry:Number = (((c>>8) & 0xFF)-127)/127;
				var rz:Number = (((c>>16) & 0xFF)-127)/127;
				var pd:Number = vx*rx+vy*ry+vz*rz;	
				rx-=pd*vx;
				ry-=pd*vy;
				rz-=pd*vz;
				p.vx = rx*dev*vl;			// perpendicular velocity
				p.vy = ry*dev*vl;
				p.vz = rz*dev*vl;
				p.nx = tx+rx*initDev*vl;	// position
				p.ny = ty+ry*initDev*vl;
				p.nz = tz+rz*initDev*vl;
				p.w = sc;		// particle scale
				p.idx = 0;		// frame index
				
				if (i==0 || i==n-1)
				{	// anchor end points
					p.vx = 0;	// perpendicular velocity
					p.vy = 0;
					p.vz = 0;
					p.nx = tx;	// position
					p.ny = ty;
					p.nz = tz;
				}
				PData.unshift(p);
			}
			
			// ----- end constrict
			p = PData.pop();
			if (p.idx>=lifeTime)	numLivePoints++;		// if was dead point
			p.nx = qx;
			p.ny = qy;
			p.nz = qz;
			p.vx = 0;
			p.vy = 0;
			p.vz = 0;
			p.w = 0;		// particle scale
			p.idx = 0;		// frame index
			PData.unshift(p);
			
		}//endfunction
		
		/**
		* clears all existing particles
		*/
		public function reset() : void
		{
			numLivePoints=0;
			skin.jointsData=null;	// to abort render
		}//endfunctioh
			
		/**
		* updates the particles positions and each particle to lookAt (lx,ly,lz)
		*/
		public function update(lx:Number,ly:Number,lz:Number) : void
		{
			if (numLivePoints==0)	
			{
				skin.jointsData=null;	// to abort render
				return;
			}
			
			//trace("numLivePoints="+numLivePoints);
			
			// ----- transform look at point to local coordinates ---
			var pt:Vector3D = new Vector3D(lx,ly,lz);
			if (skin.transform==null)	skin.transform = new Matrix4x4();
			var invT:Matrix4x4 = skin.transform.inverse();
			pt = invT.transform(pt);	// posn relative to particles space
			
			// ----- write particles positions data -----------------
			var T:Vector.<Number> = Vector.<Number>([0,1,2,nsp, pt.x,pt.y,pt.z,0.001]);	// look at point
			var n:uint = numLivePoints;
			for (var i:int=0; i<n; i++)	// nsp=num of cols in spritesheet, 0.001 to address rounding error
			{
				var p:VertexData = PData[i];
				
				// ----- simulate particles movement 
				if (p.idx<lifeTime)
				{
					T.push(p.nx,p.ny,p.nz,p.idx%totalFrames+p.w);		// tx,ty,tx,idx+scale
					p.vx = p.vx*slowdown + wind.x;
					p.vy = p.vy*slowdown + wind.y;
					p.vz = p.vz*slowdown + wind.z;
					p.nx+=p.vx;
					p.ny+=p.vy;
					p.nz+=p.vz;
					p.idx++;	// increment frame index
					if (p.idx==lifeTime && numLivePoints>0)
					{
						p.w=0;
					 	numLivePoints--;
					}
				}
			}
			
			skin.trisCnt = (n-1)*8;
			skin.jointsData = T;		// send particle transforms to mesh for GPU transformation
		}//endfuntcion
		
		/**
		* convenience function to create from a given movieClip
		*/
		public static function fromMovieClip(mc:MovieClip,sc:Number=1,blend:String="add") : StreamersEmitter
		{
			return new StreamersEmitter(movieClipToSpritesheet(mc),mc.totalFrames,sc,blend);
		}//endfunction
		
		/**
		* given a multiframe movieClip instance, returns a single bitmapData spritesheet of all frame captures
		*/
		public static function movieClipToSpritesheet(mc:MovieClip,stepRot:Number=0) : BitmapData
		{
			var w:uint = Math.ceil(mc.width);
			var h:uint = Math.ceil(mc.height);
			var n:uint = Math.ceil(Math.sqrt(mc.totalFrames));	// number of rows,cols for generated bmd
			var bmd:BitmapData = new BitmapData(w*n,h*n,true,0x00000000);
			
			// ----- start bitmap capture ---------------------------
			var rot:Number = 0;
			for (var i:int=0; i<mc.totalFrames; i++)
			{
				mc.gotoAndStop(i+1);
				var bnds:Rectangle = mc.getBounds(mc);
				var m:Matrix = new Matrix(1,0,0,1);
				m.translate(-w/2,-h/2);
				m.rotate(rot);
				m.translate(w/2,h/2);
				m.translate(w*(i%n)-bnds.left,h*int(i/n)-bnds.top);
				bmd.draw(mc,m);
				rot+=stepRot;
			}
			
			// ----- sizing down bitmap so width,height is power of 2
			var nw:uint = 1;
			var nh:uint = 1;
			while (nw<=bmd.width)	nw*=2;
			while (nh<=bmd.height)	nh*=2;
			nw/=2;	nh/=2;
			if (nw>2048) nw=2048;
			if (nh>2048) nh=2048;
			var nbmd:BitmapData = new BitmapData(nw,nh,true,0x00000000);
			nbmd.draw(bmd,new Matrix(nw/bmd.width,0,0,nh/bmd.height,0,0),null,null,null,true);
			
			return nbmd;
		}//endfunction
	}//endclass
}//endpackage