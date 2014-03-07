package core3D
{
	import flash.display.BitmapData;
	import flash.display.MovieClip;
	import flash.geom.Matrix;
	import flash.geom.Rectangle;
	import flash.geom.Vector3D;
	
	/**
	* Author: Lin Minjiang	2012/07/10	updated
	* Creates an emitter to emit particles of texture sequence specified by given movieClip.
	* Supports 120 animated billboard particles on a single mesh
	*/
	public class ParticlesEmitter
	{
		public var skin:Mesh;
		public var PData:Vector.<VertexData>;	// position, scaling and  of each particle
		
		public var spriteSheet:BitmapData;		// the spritesheet containing movieclip sequence
		public var totalFrames:uint=0;			// total frames of the movieclip
		
		public var wind:Vector3D;				// wind affecting the particles
		public var slowdown:Number=0.85;		// slowdown factor
		
		public var numLiveParticles:uint=0;
		
		private var lifeTime:uint=0;			// particle time to live after spawn
		private var nsp:uint = 1;				// number of sprites in a row in spritesheet
		
		/**
		* creates a 120 batch rendered animated bitmap particles at given positions
		*/
		public function ParticlesEmitter(sheet:BitmapData,frames:uint,sc:Number=1,blend:String="alpha") : void
		{
			var i:int=0;
			
			wind = new Vector3D(0,0,0);		// default wind
								
			// ----- generate spriteSheet ---------------------------
			spriteSheet = sheet;
			nsp = Math.ceil(Math.sqrt(frames));	// number of sprites in a row
			totalFrames = frames;
			lifeTime = totalFrames;
			
			// ----- default particle positions if not given --------
			PData = new Vector.<VertexData>();
			for (i=0; i<120; i++)	// 120 GPU batch processed billboard particles
				PData.push(new VertexData(0,0,0, 0,0,0, 0,0,0, totalFrames));
						
			var sw:int = sheet.width/nsp;		// width of single sprite in sheet
			var sh:int = sheet.height/nsp;		// height of single sprite in sheet
						
			// ----- create bitmap planes geometry ------------------
			var idxOff:int = 7;			// vertex constants register offset
			var V:Vector.<Number> = new Vector.<Number>();	// vertices data
			var I:Vector.<uint> = new Vector.<uint>();		// indices data
			var w2:Number = sw/250*sc;
			var h2:Number = sh/250*sc;
			var f:Number = 1/nsp;
			for (i=0; i<PData.length; i++)
			{
				V.push(-w2,-h2,0, 0,0, idxOff+i);		// vx,vy,vz, u,v, idx top left 
				V.push( w2,-h2,0, f,0, idxOff+i);		// vx,vy,vz, u,v, idx top right 
				V.push( w2, h2,0, f,f, idxOff+i);		// vx,vy,vz, u,v, idx bottom right 
				V.push(-w2, h2,0, 0,f, idxOff+i);		// vx,vy,vz, u,v, idx bottom left 
				
				I.push(i*4+0,i*4+1,i*4+2);		// top right tri
				I.push(i*4+0,i*4+2,i*4+3);		// bottom left tri
			}
			skin = new Mesh();
			skin.castsShadow=false;
			skin.enableLighting(false);
			skin.setAmbient(1,1,1);
			skin.setSpecular(0);
			skin.setParticles(V,I);
			skin.setTexture(spriteSheet);
			skin.setBlendMode(blend);
		}//endfunction
		
		/**
		* sets time to live for the particles
		*/
		public function setLifetime(t:uint) : void
		{
			for (var i:int=PData.length-1; i>=0; i--)
				if (PData[i].idx>=lifeTime)
					PData[i].idx=t;
			lifeTime = t;
		}//endfunction
		
		/**
		* batch emit number of a particles at (px,py,pz) of velocity (vx,vy,vz) 0<=sc<=0.9999 with random deviation, to reduce function calls
		*/
		public function batchEmit(n:uint=1,px:Number=0,py:Number=0,pz:Number=0,vx:Number=0,vy:Number=0,vz:Number=0,dev:Number=0,sc1:Number=1,sc2:Number=0.5) : void
		{
			if (sc1>0.9999)	sc1=0.9999;
			if (sc1<0)		sc1=0;
			if (sc2>0.9999)	sc2=0.9999;
			if (sc2<0)		sc2=0;
			for (var i:int=0; i<n; i++)
			{
				var p:VertexData = PData.pop();
				if (p.idx>=lifeTime)	numLiveParticles++;		// if was dead particle
				p.nx = px;		// position
				p.ny = py;
				p.nz = pz;
				var rx:Number = Math.random()-0.5;
				var ry:Number = Math.random()-0.5;
				var rz:Number = Math.random()-0.5;
				var r:Number = Math.random()*dev/Math.sqrt(rx*rx+ry*ry+rz*rz);
				p.vx = vx + rx*r;		// velocity
				p.vy = vy + ry*r;
				p.vz = vz + rz*r;
				p.u = 0;		// UV coordinate of sprite sheet
				p.v = 0;
				r = Math.random();
				p.w = sc1*r+sc2*(1-r);		// particle scale
				p.idx = 0;		// frame index
				PData.unshift(p);
			}
		}//endfunction
		
		/**
		* emit a particle at (px,py,pz) of velocity (vx,vy,vz) 0<=sc<=0.9999
		*/
		public function emit(px:Number=0,py:Number=0,pz:Number=0,vx:Number=0,vy:Number=0,vz:Number=0,sc:Number=1) : void
		{
			if (sc>0.9999)	sc=0.9999;
			if (sc<0)		sc=0;
			var p:VertexData = PData.pop();
			if (p.idx>=lifeTime)	numLiveParticles++;		// if was dead particle
			p.nx = px;		// position
			p.ny = py;
			p.nz = pz;
			p.vx = vx;		// velocity
			p.vy = vy;
			p.vz = vz;
			p.u = 0;		// UV coordinate of sprite sheet
			p.v = 0;
			p.w = sc;		// particle scale
			p.idx = 0;		// frame index
			PData.unshift(p);
		}//endfunction
		
		/**
		* clears all existing particles
		*/
		public function reset() : void
		{
			numLiveParticles=0;
			skin.jointsData=null;	// to abort render
		}//endfunctioh
			
		/**
		* updates the particles positions and each particle to lookAt (lx,ly,lz)
		*/
		public function update(lx:Number,ly:Number,lz:Number) : void
		{
			if (numLiveParticles==0)	
			{
				skin.jointsData=null;	// to abort render
				return;
			}
			
			//trace("numLiveParticles="+numLiveParticles);
			
			// ----- transform look at point to local coordinates ---
			var pt:Vector3D = new Vector3D(lx,ly,lz);
			if (skin.transform==null)	skin.transform = new Matrix4x4();
			var invT:Matrix4x4 = skin.transform.inverse();
			pt = invT.transform(pt);	// posn relative to particles space
			
			// ----- write particles positions data -----------------
			var T:Vector.<Number> = Vector.<Number>([0,1,2,nsp, pt.x,pt.y,pt.z,0.001]);	// look at point
			var n:uint = numLiveParticles;
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
					if (p.idx==lifeTime && numLiveParticles>0)
					{
						p.w=0;
					 	numLiveParticles--;
					}
				}
			}
			
			skin.trisCnt = n*2;
			skin.jointsData = T;		// send particle transforms to mesh for GPU transformation
		}//endfuntcion
		
		/**
		* convenience function to create from a given movieClip
		*/
		public static function fromMovieClip(mc:MovieClip,sc:Number=1,blend:String="alpha") : ParticlesEmitter
		{
			return new ParticlesEmitter(movieClipToSpritesheet(mc),mc.totalFrames,sc,blend);
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