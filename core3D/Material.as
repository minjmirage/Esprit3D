package core3D
{
	import flash.geom.Matrix;
	import flash.display.BitmapData;
	import flash.display3D.textures.CubeTexture;
	
	/**
	 * ...
	 * @author Minj
	 */
	public class Material
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
		
		public var changed:uint = 0;	// bits flag for changes in material, to trigger AGAL recompile
		
		public static const UPDATE_AMBIENT:uint 	= 1;
		public static const UPDATE_SPECULAR:uint 	= 2;
		public static const UPDATE_FOG:uint 		= 4;
		public static const UPDATE_TEXMAP:uint 		= 8;
		public static const UPDATE_NORMMAP:uint 	= 16;
		public static const UPDATE_SPECMAP:uint 	= 32;
		public static const UPDATE_ENVMAP:uint 		= 64;
		
		public static const BLENDMODE_NORMAL:String = "normal";
		public static const BLENDMODE_ALPHA:String 	= "alpha";
		public static const BLENDMODE_ADD:String 	= "add";
		
		public var blendSrc:String="one";			// source pixel blend mode
		public var blendDest:String="zero";			// destination pixel blend mode
		
		public var texMap:BitmapData;				// texture map, can be null
		public var normMap:BitmapData;				// normal map, can be null
		public var specMap:BitmapData;				// speclar map, can be null
		public var envMap:CubeTexture;				// environment map, can be null
		
		
		/**
		 * constructs default material with diffuse (0.5,0.5,0.5) fog (0,0,0) specStr 0.5 specHard 0.5
		 */
		public function Material(tex:BitmapData=null,norm:BitmapData=null,spec:BitmapData=null,env:CubeTexture=null):void		
		{
			texMap = tex;
			normMap = norm;
			specMap = spec;
			envMap = env;
		}//endconstr
		
		/**
		 * sets ambient lighting, forces shader recompile if necessary
		 */
		public function setAmbient(r:Number,g:Number,b:Number) : void
		{
			if ((r == 1 || g == 1 || b == 1) || (ambR==1 || ambG==1 || ambB==1))		
				changed = changed | UPDATE_AMBIENT;
			ambR = r;
			ambG = g;
			ambB = b;
		}//endfunction

		/**
		 * sets specular strength, forces shader recompile if necessary
		 */
		public function setSpecular(strength:Number,hardness:Number=0.5) : void
		{
			if (specStr==0 || strength==0)	changed = changed | UPDATE_SPECULAR;
			specStr = strength;
			specHard = hardness;
		}//endfunction
		
		/**
		 * sets fog far distance, forces shader recompile if necessary
		 */
		public function setFog(r:Number,g:Number,b:Number,fogDist:Number) : void
		{
			if (fogFar==0 || fogDist==0)	changed = changed | UPDATE_FOG;
			fogR = r;
			fogG = g;
			fogB = b;
			fogFar = fogDist;
		}//endfunction
		
		/**
		* sets/overrides new texture to this mesh
		*/
		public function setTexMap(bmd:BitmapData) : void
		{
			changed = changed | UPDATE_TEXMAP;
			texMap = powOf2Size(bmd);
			if (texMap!=null && texMap.transparent)	setBlendMode(BLENDMODE_ALPHA);
		}//endfunction

		/**
		* sets/overrides new normal map to this mesh
		*/
		public function setNormMap(bmd:BitmapData) : void
		{
			changed = changed | UPDATE_NORMMAP;
			normMap = powOf2Size(bmd);
		}//endfunction

		/**
		* sets/overrides new specular map to this mesh
		*/
		public function setSpecMap(bmd:BitmapData) : void
		{
			changed = changed | UPDATE_SPECMAP;
			specMap = powOf2Size(bmd);
		}//endfunction
		
		/**
		* blending when drawing to stage, one of "add", "alpha", "normal"
		*/
		public function setBlendMode(s:String) : void
		{
			s = s.toLowerCase();
			if (s==BLENDMODE_ADD)		{blendSrc="sourceAlpha"; blendDest="one";}
			if (s==BLENDMODE_ALPHA)		{blendSrc="sourceAlpha"; blendDest="oneMinusSourceAlpha";}
			if (s==BLENDMODE_NORMAL)	{blendSrc="one"; blendDest="zero";}
		}//endfunction
		
		public function clone():Material
		{
			var mat:Material = new Material(texMap, normMap, specMap, envMap);
			mat.ambR = ambR;
			mat.ambG = ambG;
			mat.ambB = ambB;
			mat.fogR = fogR;
			mat.fogG = fogG;
			mat.fogB = fogB;
			mat.fogFar = fogFar;
			mat.specStr = specStr;
			mat.specHard = specHard;
			mat.changed = changed;
			mat.blendSrc = blendSrc;
			mat.blendDest = blendDest;
			return mat;
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
	}//enclass
}//endpackage