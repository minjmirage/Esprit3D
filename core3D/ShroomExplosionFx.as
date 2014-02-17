package core3D
{
	import flash.geom.*;
	import flash.display.BitmapData;
	import flash.display.MovieClip;
	import flash.filters.ColorMatrixFilter;
	
	/**
	* Author: Lin Minjiang	2012/07/10	updated
	* Creates an emitter to emit particles of texture sequence specified by given movieClip.
	* Supports 120 animated billboard particles on a single mesh
	*/
	public class ShroomExplosionFx
	{
		public var skin:Mesh;
		private var Skins:Vector.<Mesh>;
		private var PDatas:Vector.<Vector.<VertexData>>;	// position, scaling and of each particle
		private var ParticlesCnt:Vector.<uint>;
		
		public var spriteSheet:BitmapData;		// the spritesheet containing movieclip sequence
		public var totalFrames:uint=0;			// total frames of the movieclip
				
		private var lifeTime:uint=0;			// particle time to live after spawn
		private var nsp:uint = 1;				// number of sprites in a row in spritesheet
		
		private var fxScale:Number=0;
		
		private var step:Function = null;
		
		/**
		* creates a 120 batch rendered animated bitmap particles at given positions
		*/
		public function ShroomExplosionFx(sheet:BitmapData,frames:uint,sc:Number=1,blend:String="alpha") : void
		{
			var i:int=0;
			
			// ----- generate spriteSheet ---------------------------
			spriteSheet = sheet;
			nsp = Math.ceil(Math.sqrt(frames));	// number of sprites in a row
			totalFrames = frames;
			lifeTime = totalFrames;
			
			var greySheet:BitmapData = new BitmapData(sheet.width,sheet.height,sheet.transparent,0x00000000);
			greySheet.applyFilter(sheet,sheet.rect,new Point(0,0),
			new ColorMatrixFilter([	0.3,0.3,0.3,0,100, 
									0.3,0.3,0.3,0,100, 
									0.3,0.3,0.3,0,100,
									0,0,0,0.5,0]));
			
			var Bmds:Vector.<BitmapData> = Vector.<BitmapData>([greySheet,sheet,sheet]);
			
			PDatas = new Vector.<Vector.<VertexData>>();
			Skins= new Vector.<Mesh>();
			ParticlesCnt = new Vector.<uint>();
			skin = new Mesh();
						
			for (var j:int=2; j>-1; j--)
			{
				// ----- default particle positions if not given --------
				var PData:Vector.<VertexData> = new Vector.<VertexData>();
				for (i=0; i<120; i++)	// 120 GPU batch processed billboard particles
					PData.push(new VertexData(0,0,0, 0,0,0, 0,0,0, totalFrames));
				PDatas.push(PData);
						
				var sw:int = sheet.width/nsp;		// width of single sprite in sheet
				var sh:int = sheet.height/nsp;		// height of single sprite in sheet
				// ----- create bitmap planes geometry ------------------
				var idxOff:int = 7;			// vertex constants register offset
				var V:Vector.<Number> = new Vector.<Number>();	// vertices data
				var I:Vector.<uint> = new Vector.<uint>();		// indices data
				var w2:Number = sw/250*sc;
				var h2:Number = sh/250*sc;
				fxScale = (w2+h2)/2;		
				
				var f:Number = 1/nsp;
				for (i=0; i<PData.length; i++)
				{
					V.push(-w2,-h2,0, 0,0, idxOff+i);	// x,y,z, u,v, idx top left 
					V.push( w2,-h2,0, f,0, idxOff+i);	// x,y,z, u,v, idx top right 
					V.push( w2, h2,0, f,f, idxOff+i);	// x,y,z, u,v, idx bottom right 
					V.push(-w2, h2,0, 0,f, idxOff+i);	// x,y,z, u,v, idx bottom left 
				
					I.push(i*4+0,i*4+1,i*4+2);		// top right tri
					I.push(i*4+0,i*4+2,i*4+3);		// bottom left tri
				}
			
				var innerSkin:Mesh = new Mesh();
				innerSkin.castsShadow=false;
				innerSkin.enableLighting(false);
				innerSkin.setAmbient(1,1,1,0);
				innerSkin.setParticles(V,I);
				//innerSkin.depthWrite = true;		// write to depth buffer
				innerSkin.setTexture(Bmds[j]);
				innerSkin.setBlendMode(blend);
				skin.addChild(innerSkin);
				Skins.push(innerSkin);
				ParticlesCnt.push(0);
			}//endfor
		}//endfunction
				
		/**
		* initiate mushroom cloud and blast ring fx
		*/
		public function blast() : void
		{
			var riseSpeed:Number=0.05*fxScale;
			var radius:Number=0.5*fxScale;
			
			// ----- create mushroom cloud step
			var stepCnt:int=0;
			step = function():void
			{
				for (var i:int=0; i<2; i++)
				{
					// ----- spawn mushroom cloud particle
					var rang:Number = Math.random()*Math.PI*2;
					var p:VertexData = PDatas[0].pop();
					if (p.idx>=lifeTime)	ParticlesCnt[0]++;		// if was dead particle
					p.nx = Math.sin(rang)*radius;	// position
					p.ny = stepCnt*riseSpeed;
					p.nz = Math.cos(rang)*radius;
					p.vx = 0;						// velocity
					p.vy = riseSpeed*2;
					p.vz = 0;
					p.u = 0;			// 
					p.v = riseSpeed;	// rising speed of spinning cloud
					p.w = Math.random()*0.5+0.5;	// particle scale
					p.idx = 0;				// frame index
					PDatas[0].unshift(p);
					
					// ----- spawn mushroom column particle
					rang = Math.random()*Math.PI*2;
					p = PDatas[1].pop();
					if (p.idx>=lifeTime)	ParticlesCnt[1]++;		// if was dead particle
					p.nx = Math.sin(rang)*radius/2;	// position
					p.ny = stepCnt*riseSpeed*Math.random();
					p.nz = Math.cos(rang)*radius/2;
					rang = Math.random();
					p.vx = p.nx*radius*rang;						// velocity
					p.vy = Math.max(-p.ny/lifeTime,-riseSpeed*rang);
					p.vz = p.nz*radius*rang;
					p.u = 0;
					p.v = 0;
					p.w = Math.random()*0.4+0.3;	// particle scale
					p.idx = 0;				// frame index
					PDatas[1].unshift(p);
				}//endfor
				stepCnt++;
				var af:Number = (120-stepCnt)/120+0.01;
				Skins[0].setAmbient(1+af,1+af,1,0);
				if (stepCnt==120)	step = null;
			}
			
			// ----- initiate spreading cloud ring
			ParticlesCnt[2]=120;
			for (var i:int=0; i<120; i++)
			{
				var rang:Number = Math.random()*Math.PI*2;
				var p:VertexData = PDatas[2].pop();
				p.nx = Math.sin(rang)*radius;	// position
				p.ny = 0;
				p.nz = Math.cos(rang)*radius;
				p.vx = p.nx*40;				// velocity
				p.vy = 0;
				p.vz = p.nz*40;
				p.u = 0;			// 
				p.v = 0;			// rising speed of spinning cloud
				p.w = Math.random()*0.5+0.4;	// particle scale
				p.idx = 0;				// frame index
				PDatas[2].unshift(p);
			}//endfor
		}//endfunction
				
		/**
		* clears all existing particles
		*/
		public function reset() : void
		{
			for (var i:int=Skins.length-1; i>-1; i--)
			{
				ParticlesCnt[i]=0;
				for (var j:int=PDatas[i].length-1; j>-1; j--)	
					PDatas[i][j].idx = lifeTime;
				Skins[i].jointsData=null;	// to abort render
			}
		}//endfunction
		
		/**
		* updates the particles positions and each particle to lookAt (lx,ly,lz)
		*/
		public function update(lx:Number,ly:Number,lz:Number) : void
		{
			if (step!=null)	step();
			
			// ----- transform look at point to local coordinates ---
			var pt:Vector3D = new Vector3D(lx,ly,lz);
			if (skin.transform==null)	skin.transform = new Matrix4x4();
			var invT:Matrix4x4 = skin.transform.inverse();
			pt = invT.transform(pt);	// posn in particles space
			
			var i:int=0;
			var n:int=0;
			var p:VertexData = null;
			
			for (var s:int=Skins.length-1; s>=0; s--)
			{
				if (ParticlesCnt[s]==0)
				{
					Skins[s].jointsData=null;	// to abort render
				}
				else	// mushroom cloud
				{
					// ----- write mushroom clouds data -----------------
					n = Math.min(ParticlesCnt[s],PDatas[s].length);
					var Sorted:Vector.<Vector3D> = new Vector.<Vector3D>();	// sorted output particle posns
					for (i=0; i<n; i++)	// nsp=num of cols in spritesheet, 0.001 to address rounding error
					{
						p = PDatas[s][i];
				
						// ----- simulate particles movement
						if (p.idx<lifeTime)
						{
							// ----- binary insert particle points in distance order from (lx,ly,lz)
							var pp:Vector3D = new Vector3D(p.nx-pt.x,p.ny-pt.y,p.nz-pt.z,p.idx%totalFrames+p.w);	// dx,dy,dx,idx+scale
							var a:int=0; 
							var b:int=Sorted.length-1;
							while (b>=a)
							{
								var m:int = (a+b)/2;
								if (Sorted[m].length>pp.length)	b=m-1;
								else							a=m+1;
							}
							Sorted.splice(a,0,pp);
							
							if (s==0)
							{
								// ----- rotational axis for the rolling effect
								var ax:Number =-p.nz*0.5;
								var ay:Number = 0
								var az:Number = p.nx*0.5;
								var al:Number = Math.sqrt(ax*ax+az*az);
								ax/=al; az/=al;
					
								// ----- shift billboard position
								p.nx+= p.vx;
								p.ny+= p.vy+p.v;
								p.nz+= p.vz;
					
								// ----- add perpenticular vel to particle
								var nv:Vector3D = new Matrix4x4().rotAbout(-ax,-ay,-az,Math.PI/32).rotateVector(new Vector3D(p.vx,p.vy,p.vz));
								p.vx = nv.x;
								p.vy = nv.y;
								p.vz = nv.z;
							}
							else if (s==1)
							{
								p.nx+= p.vx;
								p.ny+= p.vy;
								p.nz+= p.vz;
							}
							else if (s==2)
							{
								// ----- shift billboard position
								p.nx = (p.nx*99+p.vx)/100;
								p.ny = (p.ny*99+p.vy)/100;
								p.nz = (p.nz*99+p.vz)/100;
							}
							
							p.idx++;	// increment frame index
							if (p.idx==lifeTime && ParticlesCnt[s]>0)
							{
								p.w=0;
								ParticlesCnt[s]--;
							}
						}
					}//endfor i
					
					
					var T:Vector.<Number> = Vector.<Number>([0,1,2,nsp, pt.x,pt.y,pt.z,0.001]);	// look at point
					for (i=Sorted.length-1; i>-1; i--)
					{
						pp = Sorted[i];
						T.push(pp.x+pt.x,pp.y+pt.y,pp.z+pt.z,pp.w);		// tx,ty,tx,idx+scale
					}
					Skins[s].trisCnt = n*2;
					Skins[s].jointsData = T;		// send particle transforms to mesh for GPU transformation
				}//endelse
			}//endfor
			
		}//endfunction
		
	}//endclass
}//endpackage