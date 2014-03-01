package core3D
{
	public class VertexData
	{
		public var vx:Number;	// for vertex
		public var vy:Number;
		public var vz:Number;
		public var nx:Number;	// for normal
		public var ny:Number;
		public var nz:Number;
		public var tx:Number;	// for tangent
		public var ty:Number;
		public var tz:Number;
		public var u:Number;	// for UV
		public var v:Number;
		public var w:Number;
		public var idx:int;		// for weight idx
		
		public function VertexData(vx:Number=0,vy:Number=0,vz:Number=0,nx:Number=0,ny:Number=0,nz:Number=0,u:Number=0,v:Number=0,w:Number=0,idx:int=0,tx:Number=0,ty:Number=0,tz:Number=0) : void
		{
			this.vx = vx;
			this.vy = vy;
			this.vz = vz;
			this.nx = nx;
			this.ny = ny;
			this.nz = nz;
			this.tx = tx;
			this.ty = ty;
			this.tz = tz;
			this.u = u;
			this.v = v;
			this.w = w;
			this.idx = idx;
		}//endconstructor
		
		public function clone() : VertexData
		{
			return new VertexData(vx,vy,vz,nx,ny,nz,u,v,w,idx,tx,ty,tz);
		}//endfunction
		
		public function toString() : String
		{
			return int(vx*100)/100+","+int(vy*100)/100+","+int(vz*100)/100+","+int(nx*100)/100+","+int(ny*100)/100+","+int(nz*100)/100+","+w+","+idx;
		}
	}//endclass
	
}//endpackage